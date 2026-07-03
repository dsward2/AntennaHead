import SwiftUI

struct ContentView: View {
    @State private var tlsManager = TLSCertificateManager()
    @State private var authCredentials = HTTPAuthCredentials()
    @State private var httpServer = AntennaHeadHTTPServer()
    @State private var audioServer = LiveAudioServerClient()
    @State private var lasProcess = LiveAudioServerProcessManager()
    @State private var sdrController = SDRController(
        udpInputPort: LiveAudioServerProcessManager.defaultUDPInputPort)
    @State private var rtlsdrDeviceFound = true

    private var webURL: URL {
        URL(string: "http://localhost:\(httpServer.port)")!
    }

    private var liveAudioServerURL: URL {
        URL(string: "http://localhost:\(lasProcess.httpPort)")!
    }

    /// LAN-reachable web UI URL for the share picker (AirDrop etc.), so the
    /// link works from phones/tablets on the network.
    private var shareableWebURL: URL {
        URL(string: "http://\(HostInfo.shareableHost()):\(httpServer.httpPort)")!
    }

    /// LAN-reachable HTTPS web UI URL; only offered when TLS is running.
    private var shareableHTTPSWebURL: URL {
        URL(string: "https://\(HostInfo.shareableHost()):\(httpServer.httpsPort)")!
    }

    var body: some View {
        TabView {
            WebRadioView(url: webURL, credentials: authCredentials.effective)
                .tabItem { Label("LocalRadio", systemImage: "antenna.radiowaves.left.and.right") }

            WebRadioView(url: liveAudioServerURL, credentials: authCredentials.effective)
                .tabItem { Label("LiveAudioServer", systemImage: "dot.radiowaves.up.forward") }

            StatusView(sdrController: sdrController, audioServer: audioServer)
                .tabItem { Label("Status", systemImage: "waveform") }

            ConfigurationView(httpServer: httpServer, lasProcess: lasProcess, sdrController: sdrController)
                .tabItem { Label("Configuration", systemImage: "gearshape") }

            TLSSettingsView(tlsManager: tlsManager, authCredentials: authCredentials)
                .tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(minWidth: 800, minHeight: 540)
        .toolbar {
            // Share the web UI URL (AirDrop, Messages, …) — ported from
            // LocalRadio's shareWebPreviewURL / NSSharingServicePicker buttons.
            ToolbarItemGroup {
                ShareLink(item: shareableWebURL) {
                    Label("Share Web URL", systemImage: "square.and.arrow.up")
                }
                .help("Share the LocalRadio web interface URL (\(shareableWebURL.absoluteString))")
                if httpServer.httpsEnabled {
                    ShareLink(item: shareableHTTPSWebURL) {
                        Label("Share HTTPS Web URL", systemImage: "square.and.arrow.up.circle")
                    }
                    .help("Share the HTTPS web interface URL (\(shareableHTTPSWebURL.absoluteString))")
                }
            }
        }
        .onAppear {
            startServices()
            audioServer.startPolling()
            rtlsdrDeviceFound = RTLSDRUSBDevice.isConnected()
        }
        // Ported from LocalRadio's poseRTLSDRNotFoundAlert. Unlike LocalRadio,
        // services keep running — the RTL-SDR is only needed when tuning, and
        // device/custom-task audio sources work without one.
        .alert("RTL-SDR USB Device Not Found", isPresented: .init(
            get: { !rtlsdrDeviceFound },
            set: { rtlsdrDeviceFound = !$0 }
        )) {
            Button("Continue") {}
            Button("More Info") {
                NSWorkspace.shared.open(URL(string: "https://github.com/dsward2/LocalRadio")!)
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        } message: {
            Text("An RTL-SDR device was not detected on this Mac's USB ports. "
                 + "Radio tuning requires one; please check the USB connection. "
                 + "Click Continue to proceed without an RTL-SDR device "
                 + "(audio devices and custom tasks still work).")
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
        // Web Settings page stored a new output bitrate: restart the servers so
        // it takes effect (LAS encoder args + the web player's advertised type).
        .onReceive(NotificationCenter.default.publisher(for: AntennaHeadHTTPServer.settingsDidChangeNotification)) { _ in
            startServices()
        }
        // FCC Search window's Listen button (separate scene, no controller access).
        .onReceive(NotificationCenter.default.publisher(for: FCCSearchView.listenNotification)) { note in
            guard let hz = note.userInfo?["frequencyHz"] as? Int, hz > 0 else { return }
            sdrController.startTasksForFrequency(
                frequencyHz: hz,
                sampleRate: note.userInfo?["sampleRate"] as? Int ?? 170_000,
                tunerGain: note.userInfo?["tunerGain"] as? Double ?? 49.6,
                stereo: false,
                modulation: "fm")
        }
    }

    private func startServices() {
        let identity = try? tlsManager.currentIdentity()
        let auth = authCredentials.effective

        // System-wide settings (output bitrate + ports), editable from the web
        // Settings page and the Configuration tab's sheet.
        let outputBitrate = AntennaHeadHTTPServer.storedOutputBitrate(sqlite: .shared)
        let ports = PortSettings.load()

        let tlsConfig: LiveAudioServerProcessManager.TLSConfig?
        if let exported = try? tlsManager.exportedIdentity() {
            tlsConfig = .init(identityPath: exported.url.path, password: exported.password,
                              port: Int(ports.streamingHTTPS))
        } else {
            tlsConfig = nil
        }

        httpServer.httpPort = ports.webHTTP
        httpServer.httpsPort = ports.webHTTPS
        sdrController.updatePorts(udpInput: ports.audioUDP, statusUDP: ports.statusUDP)

        // The web UI's audio player points at LiveAudioServer's AAC stream.
        let webConfig = AntennaHeadHTTPServer.WebConfig(
            streamHTTPPort: Int(ports.streamingHTTP),
            streamHTTPSPort: tlsConfig?.port,
            aacBitrate: outputBitrate
        )
        // Let web routes read favorites and drive tuning.
        httpServer.sdrController = sdrController
        httpServer.sqlite = .shared
        httpServer.start(tlsIdentity: identity, auth: auth, webConfig: webConfig)
        audioServer.credentials = auth

        lasProcess.start(auth: auth, tls: tlsConfig, outputBitrate: outputBitrate,
                         httpPort: ports.streamingHTTP, udpInputPort: ports.audioUDP)
    }

    private func teardownServices() {
        sdrController.terminateTasks()
        httpServer.stop()
        audioServer.stopPolling()
        lasProcess.stop()
    }
}
