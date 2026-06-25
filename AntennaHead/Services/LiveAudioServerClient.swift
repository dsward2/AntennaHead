import Foundation
import Observation

@Observable
final class LiveAudioServerClient {
    var listenerCount: Int = 0
    var isRunning: Bool = false
    var nowPlaying: NowPlaying = .empty

    private let baseURL: URL
    private var statusTask: Task<Void, Never>?

    /// Active Basic-auth credentials applied to every outbound request, or
    /// `nil` when auth is disabled. Update from the MainActor when settings
    /// change; reads from the polling task are racy but only ever swap
    /// between sendable value snapshots, so a stale read is at worst a single
    /// 401 retry.
    var credentials: HTTPAuthCredentials.Credentials?

    init(port: Int = 8080) {
        self.baseURL = URL(string: "http://localhost:\(port)")!
    }

    func startPolling() {
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        statusTask?.cancel()
        statusTask = nil
    }

    func setNowPlaying(title: String, artist: String = "", station: String = "") async {
        guard let url = URL(string: "\(baseURL)/api/now-playing") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        attachAuth(to: &request)
        let body = ["title": title, "artist": artist, "station": station]
        request.httpBody = try? JSONEncoder().encode(body)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func fetchStatus() async {
        guard let url = URL(string: "\(baseURL)/status.json") else { return }
        var request = URLRequest(url: url)
        attachAuth(to: &request)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let status = try? JSONDecoder().decode(ServerStatus.self, from: data) else { return }
        listenerCount = status.listeners
        isRunning = true
    }

    private func attachAuth(to request: inout URLRequest) {
        guard let creds = credentials else { return }
        let token = Data("\(creds.user):\(creds.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
}

extension LiveAudioServerClient {
    struct NowPlaying {
        var title: String
        var artist: String
        var station: String
        static let empty = NowPlaying(title: "", artist: "", station: "")
    }

    private struct ServerStatus: Decodable {
        var listeners: Int
    }
}
