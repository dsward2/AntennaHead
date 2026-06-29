import SwiftUI

struct ContentView: View {
    @State private var tlsManager = TLSCertificateManager()
    @State private var authCredentials = HTTPAuthCredentials()
    @State private var httpServer = AntennaHeadHTTPServer()
    @State private var audioServer = LiveAudioServerClient()
    @State private var lasProcess = LiveAudioServerProcessManager()
    @State private var sdrController = SDRController(
        udpInputPort: LiveAudioServerProcessManager.defaultUDPInputPort)

    private var webURL: URL {
        URL(string: "http://localhost:\(httpServer.port)")!
    }

    private var liveAudioServerURL: URL {
        URL(string: "http://localhost:\(lasProcess.httpPort)")!
    }

    var body: some View {
        TabView {
            WebRadioView(url: webURL, credentials: authCredentials.effective)
                .tabItem { Label("LocalRadio", systemImage: "antenna.radiowaves.left.and.right") }

            WebRadioView(url: liveAudioServerURL, credentials: authCredentials.effective)
                .tabItem { Label("LiveAudioServer", systemImage: "dot.radiowaves.up.forward") }

            StatusView(audioServer: audioServer)
                .tabItem { Label("Status", systemImage: "waveform") }

            ConfigurationView(sdrController: sdrController, audioServer: audioServer)
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
            teardownServices()
        }
        // onDisappear is unreliable at app quit; willTerminate fires on a clean
        // Cmd-Q / Quit, ensuring helpers (LiveAudioServer + the radio pipeline)
        // are reaped instead of orphaned. (A crash is handled helper-side by
        // PCMUDPSender's --exit-with-parent watchdog.)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            teardownServices()
        }
        .onReceive(NotificationCenter.default.publisher(for: HTTPAuthCredentials.didChangeNotification)) { _ in
            startServices()
        }
    }

    private func startServices() {
        let identity = try? tlsManager.currentIdentity()
        let auth = authCredentials.effective

        let tlsConfig: LiveAudioServerProcessManager.TLSConfig?
        if let exported = try? tlsManager.exportedIdentity() {
            tlsConfig = .init(identityPath: exported.url.path, password: exported.password)
        } else {
            tlsConfig = nil
        }

        // The web UI's audio player points at LiveAudioServer's AAC stream.
        let webConfig = AntennaHeadHTTPServer.WebConfig(
            streamHTTPPort: lasProcess.httpPort,
            streamHTTPSPort: tlsConfig?.port
        )
        // Let web routes read favorites and drive tuning.
        httpServer.sdrController = sdrController
        httpServer.sqlite = .shared
        httpServer.start(tlsIdentity: identity, auth: auth, webConfig: webConfig)
        audioServer.credentials = auth

        lasProcess.start(auth: auth, tls: tlsConfig)
    }

    private func teardownServices() {
        sdrController.terminateTasks()
        httpServer.stop()
        audioServer.stopPolling()
        lasProcess.stop()
    }
}
