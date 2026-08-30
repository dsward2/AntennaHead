import SwiftUI

struct ContentView: View {
    @State private var tlsManager = TLSCertificateManager()
    @State private var authCredentials = HTTPAuthCredentials()
    @State private var httpServer = AntennaHeadHTTPServer()
    @State private var audioServer = LiveAudioServerClient()
    @State private var lasProcess = LiveAudioServerProcessManager()
    @State private var sdrController = SDRController(
        udpInputPort: LiveAudioServerProcessManager.defaultUDPInputPort)
    @State private var airPlayReceiverProcessManager = AirPlayReceiverProcessManager()
    @State private var rtlsdrDeviceFound = true
    // ControlBooth's AppleEvents control channel ('AntH' Strt/Stop/Runs).
    @State private var controlBoothEvents: ControlBoothEventReceiver?

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


    var body: some View {
        VStack(spacing: 0) {
            // Ported from LocalRadio: the web UI URL in large Courier type at the
            // top of the window; clicking opens it in the default browser.
            Button {
                NSWorkspace.shared.open(shareableWebURL)
            } label: {
                Text(shareableWebURL.absoluteString)
                    .font(.custom("Courier", size: 20))
            }
            .buttonStyle(.plain)
            .help("Open \(shareableWebURL.absoluteString) in the default web browser")
            .padding(.top, 8)
            .padding(.bottom, 4)

            tabs
        }
        .background(Color.appBackground)
        .frame(minWidth: 800, minHeight: 540)
        .toolbar {
            // Share the web UI URL (AirDrop, Messages, …) — ported from
            // LocalRadio's shareWebPreviewURL / NSSharingServicePicker buttons.
            ToolbarItemGroup {
                ShareLink(item: shareableWebURL) {
                    Label("Share Web URL", systemImage: "square.and.arrow.up")
                }
                .help("Share the AntennaHead web interface URL (\(shareableWebURL.absoluteString))")
            }
        }
        .onAppear {
            if controlBoothEvents == nil {
                controlBoothEvents = ControlBoothEventReceiver(sdrController: sdrController,
                                                               lasManager: lasProcess)
            }
            rtlsdrDeviceFound = RTLSDRUSBDevice.isConnected()
            Task { @MainActor in
                await HelperProcessPreflight.terminateOrphanedHelpers()
                startServices()
                audioServer.startPolling()
            }
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
                NSWorkspace.shared.open(URL(string: "https://github.com/dsward2/AntennaHead")!)
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
                stereo: note.userInfo?["stereo"] as? Bool ?? true,
                modulation: "wfm")
        }
    }

    private var tabs: some View {
        TabView {
            WebRadioView(url: webURL, credentials: authCredentials.effective)
                .tabItem { Label("AntennaHead", systemImage: "antenna.radiowaves.left.and.right") }

            StatusView(sdrController: sdrController, audioServer: audioServer, lasProcess: lasProcess)
                .tabItem { Label("Status", systemImage: "waveform") }

            ConfigurationView(httpServer: httpServer, lasProcess: lasProcess, sdrController: sdrController,
                             airPlayReceiverProcessManager: airPlayReceiverProcessManager)
                .tabItem { Label("Configuration", systemImage: "gearshape") }

            TLSSettingsView(tlsManager: tlsManager, authCredentials: authCredentials)
                .tabItem { Label("Security", systemImage: "lock.shield") }

            WebRadioView(url: liveAudioServerURL, credentials: authCredentials.effective)
                .tabItem { Label("LiveAudioServer", systemImage: "dot.radiowaves.up.forward") }
        }
    }

    private func startServices() {
        defer {
            // Reload both web views after the servers restart so existing pages
            // don't get stuck with failed connections from the previous instance.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                NotificationCenter.default.post(name: WebRadioView.reloadNotification, object: nil)
            }
        }
        let identity = tlsManager.isHTTPSEnabled ? (try? tlsManager.currentIdentity()) : nil
        let auth = authCredentials.effective

        // System-wide settings (output bitrate + ports), editable from the web
        // Settings page and the Configuration tab's sheet.
        let outputBitrate = AntennaHeadHTTPServer.storedOutputBitrate(sqlite: .shared)
        let ports = PortSettings.load()

        let tlsConfig: LiveAudioServerProcessManager.TLSConfig?
        if tlsManager.isHTTPSEnabled, let exported = try? tlsManager.exportedIdentity() {
            tlsConfig = .init(identityPath: exported.url.path, password: exported.password,
                              port: Int(ports.streamingHTTPS))
        } else {
            tlsConfig = nil
        }

        httpServer.httpPort = ports.webHTTP
        httpServer.httpsPort = ports.webHTTPS
        sdrController.updatePorts(udpInput: ports.audioUDP, statusUDP: ports.statusUDP,
                                   controlBoothReceive: ports.controlBoothUDP,
                                   airPlayReceive: ports.airPlayUDP)

        let controlBoothEnabled = ((try? SQLiteController.shared.appSettingsValue(
            forKey: "AntennaHeadControlBoothEnabled")) ?? nil) == "1"
        let airPlayReceiverEnabled = ((try? SQLiteController.shared.appSettingsValue(
            forKey: "AntennaHeadAirPlayReceiverEnabled")) ?? nil) == "1"

        // The web UI's audio player is proxied through this server's own port
        // (selfHTTPPort/selfHTTPSPort) rather than pointed directly at
        // LiveAudioServer's separate port — see WebConfig.selfHTTPPort's doc
        // comment — while streamHTTPPort/streamHTTPSPort remain LAS's real
        // ports, used internally by proxyToLiveAudioServer.
        let webConfig = AntennaHeadHTTPServer.WebConfig(
            streamHTTPPort: Int(ports.streamingHTTP),
            streamHTTPSPort: tlsConfig?.port,
            aacBitrate: outputBitrate,
            controlBoothEnabled: controlBoothEnabled,
            airPlayReceiverEnabled: airPlayReceiverEnabled,
            selfHTTPPort: Int(ports.webHTTP),
            selfHTTPSPort: identity != nil ? Int(ports.webHTTPS) : nil
        )
        // Let web routes read favorites, drive tuning, and reflect AirPlay status.
        httpServer.sdrController = sdrController
        httpServer.airPlayReceiverProcessManager = airPlayReceiverProcessManager
        httpServer.liveAudioServerProcessManager = lasProcess
        httpServer.sqlite = .shared
        httpServer.start(tlsIdentity: identity, auth: auth, webConfig: webConfig)
        audioServer.credentials = auth
        audioServer.port = Int(ports.streamingHTTP)

        lasProcess.start(auth: auth, tls: tlsConfig, outputBitrate: outputBitrate,
                         httpPort: ports.streamingHTTP, udpInputPort: ports.audioUDP)

        if airPlayReceiverEnabled {
            let deviceName = ((try? SQLiteController.shared.appSettingsValue(
                forKey: "AntennaHeadAirPlayReceiverDeviceName")) ?? nil) ?? "AntennaHead"
            airPlayReceiverProcessManager.start(deviceName: deviceName, udpPort: ports.airPlayUDP)
        } else {
            airPlayReceiverProcessManager.stop()
        }
    }

    private func teardownServices() {
        sdrController.terminateTasks()
        airPlayReceiverProcessManager.stop()
        httpServer.stop()
        audioServer.stopPolling()
        lasProcess.stop()
    }
}
