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

    private var pathSatisfied = true
    private var internetAnswered = true
    private let monitor = NWPathMonitor()
    private var onChange: (Bool) -> Void = { _ in }
    private var recheck: Task<Void, Never>?

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in
                self?.pathSatisfied = ok
                self?.internetAnswered = ok   // a new path deserves a fresh try
                self?.update()
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
        guard now != isOnline else { return }
        isOnline = now
        onChange(now)
    }
}
