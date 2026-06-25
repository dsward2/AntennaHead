import SwiftUI

struct ContentView: View {
    @State private var tlsManager = TLSCertificateManager()
    @State private var authCredentials = HTTPAuthCredentials()
    @State private var httpServer = AntennaHeadHTTPServer()
    @State private var audioServer = LiveAudioServerClient()
    @State private var lasProcess = LiveAudioServerProcessManager()

    private var webURL: URL {
        URL(string: "http://localhost:\(httpServer.port)")!
    }

    var body: some View {
        TabView {
            WebRadioView(url: webURL)
                .tabItem { Label("LocalRadio", systemImage: "antenna.radiowaves.left.and.right") }

            StatusView(audioServer: audioServer)
                .tabItem { Label("Status", systemImage: "waveform") }

            ConfigurationView()
                .tabItem { Label("Configuration", systemImage: "gearshape") }

            TLSSettingsView(tlsManager: tlsManager, authCredentials: authCredentials)
                .tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(minWidth: 800, minHeight: 540)
        .onAppear {
            startServices()
            audioServer.startPolling()
        }
        .onDisappear {
            httpServer.stop()
            audioServer.stopPolling()
            lasProcess.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: HTTPAuthCredentials.didChangeNotification)) { _ in
            startServices()
        }
    }

    private func startServices() {
        let identity = try? tlsManager.currentIdentity()
        let auth = authCredentials.effective
        httpServer.start(tlsIdentity: identity, auth: auth)
        audioServer.credentials = auth

        let tlsConfig: LiveAudioServerProcessManager.TLSConfig?
        if let exported = try? tlsManager.exportedIdentity() {
            tlsConfig = .init(identityPath: exported.url.path, password: exported.password)
        } else {
            tlsConfig = nil
        }
        lasProcess.start(auth: auth, tls: tlsConfig)
    }
}
