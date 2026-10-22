// Entry point, scenes, menu commands and app lifecycle.
import AppKit
import SwiftUI
import WebKit

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.runBlocking()) }
        VideoSummarizerApp.main()
    }
}

struct VideoSummarizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(AppSettings.isPreview ? "Video Buddy 4.0 Preview" : "Video Buddy", id: "main") {
            ThemedRoot { RootView() }
                .environment(AppModel.shared)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1560, height: 940)
        .commands { AppCommands() }

        Settings {
            ThemedRoot { SettingsView() }
                .environment(AppModel.shared)
        }
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        // ⌘W: in the YouTube section it closes the tab (the window stays, as in Safari with tabs); elsewhere the window
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                let m = AppModel.shared
                let w = NSApp.keyWindow
                if m.section == .youtube, w == nil || w === m.browser.tab?.webView?.window { m.browser.closeActive() } else { w?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
        CommandMenu("Tab") {
            Button("New Tab") { AppModel.shared.newBrowserTab() }.keyboardShortcut("t")
            Button("Reopen Closed Tab") { AppModel.shared.reopenTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Duplicate Tab") { AppModel.shared.inBrowser { b in if let t = b.tab { b.duplicate(t) } } }
            Divider()
            Button("Show Next Tab") { AppModel.shared.inBrowser { $0.selectTab(offset: 1) } }.keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { AppModel.shared.inBrowser { $0.selectTab(offset: -1) } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab") { AppModel.shared.inBrowser { $0.selectTab(offset: 1) } }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { AppModel.shared.inBrowser { $0.selectTab(offset: -1) } }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<9) { n in
                Button("Tab \(n)") { AppModel.shared.inBrowser { $0.selectTab(number: n) } }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Button("Last Tab") { AppModel.shared.inBrowser { $0.selectTab(number: 9) } }.keyboardShortcut("9")
        }
        CommandGroup(after: .newItem) {
            // in the YouTube section ⌘L focuses the address field (same token, the browser toolbar listens)
            Button("Focus Link Field") { AppModel.shared.focusLinkToken += 1 }.keyboardShortcut("l")
            Button("Paste Link") { AppModel.shared.pasteLink() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Summarize") { AppModel.shared.start(.summary) }.keyboardShortcut(.return)
            Button("Download Audio") { AppModel.shared.start(.audio) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Download Video") { AppModel.shared.start(.video) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Cancel Processing") { AppModel.shared.jobs.cancel() }.keyboardShortcut(".")
            Divider()
            Button("Find in Library") {
                if ![.home, .library, .favorites].contains(AppModel.shared.section) { AppModel.shared.section = .library }
                AppModel.shared.focusSearchToken += 1
            }
            .keyboardShortcut("f")
        }
        CommandMenu("Playback") {
            Button("Play / Pause") {
                let m = AppModel.shared
                if m.playback.player != nil { m.playback.togglePlayPause() } else if let v = m.store.selectedVideo { m.play(v) }
            }
            .keyboardShortcut("k")
            // 4.0: in the YouTube section ⌘[ / ⌘] are the browser's Back / Forward (as in Safari); elsewhere ±10 s
            Button("Back 10 Seconds (Back in YouTube)") {
                let m = AppModel.shared
                if m.section == .youtube { m.browser.tab?.goBack() } else { m.playback.skip(-10) }
            }
            .keyboardShortcut("[")
            Button("Forward 10 Seconds (Forward in YouTube)") {
                let m = AppModel.shared
                if m.section == .youtube { m.browser.tab?.goForward() } else { m.playback.skip(10) }
            }
            .keyboardShortcut("]")
            Button("Reload Page") { if AppModel.shared.section == .youtube { AppModel.shared.browser.tab?.reload() } }
                .keyboardShortcut("r")
            Divider()
            Button("Close Player") { AppModel.shared.playback.stop() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-job asks first, then stops the whole job tree before the app goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let jobs = AppModel.shared.jobs, playback = AppModel.shared.playback
            guard jobs.current != nil else {
                guard playback.currentPath != nil else { return .terminateNow }
                // write the playback position before going away, so the video resumes there next time
                Task { @MainActor in
                    await playback.savePositionNow()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
            let alert = NSAlert()
            alert.messageText = "A video is still being processed"
            alert.informativeText = "Quit and cancel it? Files that were already saved stay where they are."
            alert.addButton(withTitle: "Quit and Cancel")
            alert.addButton(withTitle: "Keep Working")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            jobs.cancel()
            Task { @MainActor in
                for _ in 0..<60 where jobs.current != nil { try? await Task.sleep(for: .milliseconds(100)) }
                await playback.savePositionNow()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sizeWindowOnce()
        MainActor.assumeIsolated { TestHooks.install() }
        // test hook: with VS_SNAPSHOT_DIR set, a distributed notification saves a picture of the window (no screen-recording permission needed)
        guard let dir = ProcessInfo.processInfo.environment["VS_SNAPSHOT_DIR"] else { return }
        let channel = ProcessInfo.processInfo.environment["VS_TEST_CHANNEL"].map { ".\($0)" } ?? ""
        DistributedNotificationCenter.default().addObserver(forName: .init("local.video-summarizer.snapshot" + channel), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Snapshot.save(to: dir) }
        }
    }
}

extension AppDelegate {
    /// 2.0 needs a much larger window than 1.0 left behind, so size it once on first launch
    /// (VS_WINDOW_SIZE=WxH forces a size, for tests).
    @MainActor func sizeWindowOnce() {
        let forced = ProcessInfo.processInfo.environment["VS_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        let key = "didSizeWindow2"
        guard forced?.count == 2 || !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
                  let screen = window.screen?.visibleFrame else { return }
            let w = forced.map { $0[0] } ?? min(1560, screen.width - 60)
            let h = forced.map { $0[1] } ?? min(940, screen.height - 60)
            window.setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: true)
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}

enum Snapshot {
    @MainActor static func save(to dir: String) {
        Task {
            for (i, window) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                // web pages draw in WebKit's own process, so cacheDisplay leaves them blank: paint each one's own snapshot in
                for web in webViews(in: view) where web.window != nil && !web.isHidden {
                    guard let image = try? await web.takeSnapshot(configuration: nil) else { continue }
                    let rect = web.convert(web.bounds, to: nil)   // window coordinates (origin bottom-left), like the bitmap
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    image.draw(in: rect)
                    NSGraphicsContext.restoreGraphicsState()
                }
                let name = i == 0 ? "window.png" : "window-\(i).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }

    @MainActor private static func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
}
