import SwiftUI

struct ContentView: View {
    @State private var tlsManager = TLSCertificateManager()
    @State private var audioServer = LiveAudioServerClient()
    @State private var httpServer = AntennaHeadHTTPServer()

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
        }
        .frame(minWidth: 800, minHeight: 540)
        .onAppear {
            let identity = try? tlsManager.currentIdentity()
            httpServer.start(tlsIdentity: identity)
            audioServer.startPolling()
        }
        .onDisappear {
            httpServer.stop()
            audioServer.stopPolling()
        }
    }
}
