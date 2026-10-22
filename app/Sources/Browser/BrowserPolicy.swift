// 4.0: what a YouTube address is (from the URL only: no page scraping) and where a navigation may go.
// Pure functions, so they're covered by the self-test.
import Foundation

/// The kind of YouTube page an address is, as far as the URL tells.
enum YouTubePage: Equatable {
    case home
    case video(id: String, playlist: String?)
    case shorts(id: String)
    case playlist(id: String)
    case channel(String)
    case search(String)
    case signIn
    case consent
    case otherYouTube
    case other(host: String)
    case blank

    /// The video's id on a watch or Shorts page.
    var videoID: String? {
        switch self {
        case let .video(id, _), let .shorts(id): id
        default: nil
        }
    }

    var label: String {
        switch self {
        case .home: "Home"
        case .video: "Video"
        case .shorts: "Short"
        case .playlist: "Playlist"
        case .channel: "Channel"
        case .search: "Search"
        case .signIn: "Google sign-in"
        case .consent: "Cookie consent"
        case .otherYouTube: "YouTube"
        case let .other(host): host
        case .blank: "New tab"
        }
    }
}

enum BrowserPolicy {
    /// Where a navigation goes.
    enum Decision: Equatable {
        case allow
        case openExternally     // in the default browser
        case cancel             // downloads, file://, unknown schemes
    }

    static let home = URL(string: "https://www.youtube.com/")!

    /// Hosts the YouTube section loads itself: YouTube, and the Google pages its sign-in, EU consent and
    /// "unusual traffic" check need (only those paths on google.com, so Google search opens in your browser).
    static func isInApp(host: String, path: String = "/") -> Bool {
        let h = host.lowercased()
        let youtube = ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        if youtube.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return true }
        if h == "accounts.google.com" || h == "consent.google.com" { return true }
        return (h == "www.google.com" || h == "google.com") && ["/sorry", "/accounts", "/recaptcha"].contains { path.hasPrefix($0) }
    }

    static func classify(_ url: URL?) -> YouTubePage {
        guard let url, let scheme = url.scheme?.lowercased() else { return .blank }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return .blank }
        if host == "accounts.google.com" || host == "accounts.youtube.com" { return .signIn }
        if host.hasPrefix("consent.") { return .consent }
        guard isInApp(host: host), host.contains("youtu") else { return .other(host: host) }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = { (name: String) in comps?.queryItems?.first { $0.name == name }?.value?.nilIfBlank }
        let parts = url.path.split(separator: "/").map(String.init)
        if let ref = VideoRef.parse(url.absoluteString), let id = ref.youtubeID {
            return parts.first == "shorts" ? .shorts(id: id) : .video(id: id, playlist: query("list"))
        }
        switch parts.first {
        case nil: return .home
        case "playlist": return query("list").map { .playlist(id: $0) } ?? .otherYouTube
        case "results": return .search((query("search_query") ?? "").replacingOccurrences(of: "+", with: " "))   // YouTube writes spaces as +
        case let first? where first.hasPrefix("@"): return .channel(first)
        case "channel", "c", "user": return parts.count > 1 ? .channel(parts[1]) : .otherYouTube
        default: return .otherYouTube
        }
    }

    /// Main-frame navigations stay in the app only for YouTube (and Google's sign-in/consent pages); anything else opens
    /// in the default browser. Frames inside a page (players, ads) are the page's business. No downloads, no file://.
    static func decide(_ url: URL, mainFrame: Bool) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "https", "http":
            guard mainFrame else { return .allow }
            return isInApp(host: url.host ?? "", path: url.path) ? .allow : .openExternally
        case "about", "blob", "data": return mainFrame && scheme != "about" ? .cancel : .allow
        case "mailto", "tel": return .openExternally
        default: return .cancel     // file:, javascript: from outside, custom schemes
        }
    }

    /// The address field: a link (with or without https://) goes there; anything else searches YouTube.
    static func address(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()), url.host != nil { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), let host = url.host, host.contains(".") { return url }
        var comps = URLComponents(string: "https://www.youtube.com/results")!
        comps.queryItems = [URLQueryItem(name: "search_query", value: text)]
        return comps.url
    }

    /// The canonical watch link Video Buddy's actions use for a page's video.
    static func watchURL(_ id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }
}
