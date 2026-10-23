// Knows whether the internet is reachable, so network jobs wait instead of failing (planes, trains, captive Wi-Fi).
import Foundation
import Network
import Observation

@MainActor @Observable
final class NetworkMonitor {
    /// What the app acts on: a network path exists, the internet answered, and no test override says otherwise.
    private(set) var isOnline = true
    /// Test-only: VS_FORCE_OFFLINE=1 or the `offline on` test command.
    var forcedOffline = ProcessInfo.processInfo.environment["VS_FORCE_OFFLINE"] == "1" { didSet { update() } }
    /// 4.0 Phase 4: Wi-Fi or Ethernet that macOS doesn't mark as expensive or constrained (see `NetworkRule`). Starts
    /// false: until macOS has described the network, the Wi-Fi-only setting waits.
    private(set) var isUnmetered = false
    /// Test-only: what kind of network to pretend this is ("wifi", "ethernet", "hotspot", "lowdata", "cellular", "other").
    var forcedPath: String? { didSet { pathFlags = forcedPath.map(NetworkRule.flags(pretending:)) ?? realFlags; update() } }
    private var realFlags = NetworkRule.Flags()
    private var pathFlags = NetworkRule.Flags()

    private var pathSatisfied = true
    private var internetAnswered = true
    private let monitor = NWPathMonitor()
    private var onChange: (Bool) -> Void = { _ in }
    private var recheck: Task<Void, Never>?

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let flags = NetworkRule.Flags(expensive: path.isExpensive, constrained: path.isConstrained,
                                          wifi: path.usesInterfaceType(.wifi), ethernet: path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                guard let self else { return }
                self.pathSatisfied = ok
                self.internetAnswered = ok   // a new path deserves a fresh try
                self.realFlags = flags
                if self.forcedPath == nil { self.pathFlags = flags }
                self.update()
            }
        }
        monitor.start(queue: DispatchQueue(label: "vs.network"))
        update()
    }

    /// Plane and hotel Wi-Fi often report "connected" while only a login page answers. Before a network job,
    /// make one quick real request; if it fails, treat the Mac as offline and look again in 30 s.
    func verifyInternet() async -> Bool {
        guard isOnline else { return false }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/generate_204")!, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        let ok: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400
        } catch {
            ok = false
        }
        if !ok {
            internetAnswered = false
            update()
            recheck?.cancel()
            recheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.internetAnswered = true
                self?.update()
            }
        }
        return ok
    }

    private func update() {
        let now = pathSatisfied && internetAnswered && !forcedOffline
        let unmetered = now && NetworkRule.unmetered(pathFlags)
        guard now != isOnline || unmetered != isUnmetered else { return }
        isOnline = now
        isUnmetered = unmetered
        onChange(now)      // the queue looks again (a download waiting for Wi-Fi can start now)
    }
}

/// 4.0 Phase 4: the Wi-Fi-only setting, conservatively. Allowed only on Wi-Fi or Ethernet that macOS doesn't mark as
/// expensive (cellular, an iPhone's Personal Hotspot) or constrained (Low Data Mode); anything else waits. macOS
/// can't recognise every metered network: a travel router or another phone's hotspot can look like ordinary Wi-Fi.
enum NetworkRule {
    struct Flags: Equatable {
        var expensive = false, constrained = false, wifi = false, ethernet = false
    }

    static func unmetered(_ f: Flags) -> Bool { !f.expensive && !f.constrained && (f.wifi || f.ethernet) }

    static func flags(pretending kind: String) -> Flags {
        switch kind {
        case "wifi": Flags(wifi: true)
        case "ethernet": Flags(ethernet: true)
        case "hotspot": Flags(expensive: true, wifi: true)          // an iPhone hotspot: Wi-Fi, marked expensive
        case "lowdata": Flags(constrained: true, wifi: true)
        case "cellular": Flags(expensive: true)
        default: Flags()                                            // "other": a VPN or an interface macOS doesn't name
        }
    }
}
