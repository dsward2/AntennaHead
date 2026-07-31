import SwiftUI
import UniformTypeIdentifiers

/// Configuration tab, mirroring LocalRadio's Configuration tab: grouped boxes
/// showing the web-host ports, helper ports, and AAC settings, plus
/// "Show Config Files in Finder" and a "Change Configuration…" edit sheet.
/// Ports are fixed constants in AntennaHead, so only the output bitrate is
/// editable; saving restarts services via `settingsDidChangeNotification`.
struct ConfigurationView: View {
    var httpServer: AntennaHeadHTTPServer
    var lasProcess: LiveAudioServerProcessManager
    var sdrController: SDRController
    var airPlayReceiverProcessManager: AirPlayReceiverProcessManager

    @State private var outputBitrate = AntennaHeadHTTPServer.defaultOutputBitrate
    /// LAS doesn't expose its TLS port, so show the configured value.
    @State private var streamingHTTPSPort = PortSettings.default.streamingHTTPS
    @State private var showingEditSheet = false
    @State private var controlBoothEnabled = false
    @State private var controlBoothAppPath = "/Applications/ControlBooth.app"
    @State private var launchControlBoothOnStartup = false
    @State private var airPlayReceiverEnabled = false
    @State private var airPlayReceiverDeviceName = "AntennaHead"

    private static let controlBoothEnabledKey = "AntennaHeadControlBoothEnabled"
    static let controlBoothPathKey = "AntennaHeadControlBoothAppPath"
    static let controlBoothAutoLaunchKey = "AntennaHeadControlBoothAutoLaunch"
    static let controlBoothBookmarkKey = "AntennaHeadControlBoothBookmark"
    private static let airPlayReceiverEnabledKey = "AntennaHeadAirPlayReceiverEnabled"
    private static let airPlayReceiverDeviceNameKey = "AntennaHeadAirPlayReceiverDeviceName"

    var body: some View {
        Form {
            Section("AntennaHead Web Host") {
                portRow("AntennaHead Web Server HTTP Port:", Int(httpServer.httpPort))
                httpsPortRow("AntennaHead Web Server HTTPS Port:", Int(httpServer.httpsPort))
                portRow("Streaming Server HTTP Port:", lasProcess.httpPort)
                httpsPortRow("Streaming Server HTTPS Port:", Int(streamingHTTPSPort))
                if let lastError = httpServer.lastError {
                    Text("\(lastError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Other Ports") {
                portRow("Status Port (UDP):", Int(sdrController.statusUDPPort))
                portRow("Audio Port (UDP):", Int(sdrController.udpInputPort))
                portRow("ControlBooth Receive Port (UDP):", Int(sdrController.controlBoothReceivePort))
                portRow("AirPlay Receive Port (UDP):", Int(sdrController.airPlayReceivePort))
            }

            Section("AAC Settings") {
                LabeledContent("Bitrate:") {
                    Text("\(outputBitrate / 1000) kbps")
                        .monospacedDigit()
                }
            }

            Section("ControlBooth") {
                Toggle("Enable remote control with ControlBooth app", isOn: $controlBoothEnabled)
                    .onChange(of: controlBoothEnabled) { _, _ in
                        saveControlBoothSettings()
                        NotificationCenter.default.post(
                            name: AntennaHeadHTTPServer.settingsDidChangeNotification, object: nil)
                    }
                HStack {
                    Text("App Path:")
                    TextField(text: $controlBoothAppPath,
                              prompt: Text("/Applications/ControlBooth.app")) { EmptyView() }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onSubmit(saveControlBoothSettings)
                    Button("Set Path") {
                        chooseControlBoothApp()
                    }
                }
                Toggle("Launch ControlBooth when AntennaHead starts", isOn: $launchControlBoothOnStartup)
                    .onChange(of: launchControlBoothOnStartup) { _, _ in
                        saveControlBoothSettings()
                    }
            }

            Section {
                if let recordingFolderURL = SharedRecordingFolder.url {
                    LabeledContent("Folder") {
                        HStack {
                            Text(recordingFolderURL.path)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([recordingFolderURL])
                            }
                        }
                    }
                } else {
                    Text("Unavailable — check AntennaHead's App Group entitlement.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Where ControlBooth-triggered recordings (schedule events, \"Test Recording Now\") and LiveAudioServer tab recordings are written — a fixed folder shared with ControlBooth via an App Group, not user-configurable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable AirPlay Receiver", isOn: $airPlayReceiverEnabled)
                    .onChange(of: airPlayReceiverEnabled) { _, enabled in
                        saveAirPlayReceiverSettings()
                        // Start/stop only the AirPlay capture pipeline — posting the
                        // broad settingsDidChangeNotification here used to also
                        // restart the web server and LiveAudioServer, racing their
                        // ports against the just-torn-down listeners (see
                        // AntennaHeadHTTPServer's silent bind-failure bug this
                        // uncovered). The capture pipeline always targets its own
                        // dedicated airPlayReceivePort, not LiveAudioServer's input
                        // directly — use the web UI's AirPlay "Listen" button to
                        // route it to the live stream.
                        if enabled {
                            airPlayReceiverProcessManager.start(deviceName: airPlayReceiverDeviceName,
                                                                udpPort: sdrController.airPlayReceivePort)
                        } else {
                            airPlayReceiverProcessManager.stop()
                        }
                    }
                HStack {
                    Text("Device Name:")
                    TextField(text: $airPlayReceiverDeviceName, prompt: Text("AntennaHead")) { EmptyView() }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onSubmit(saveAirPlayReceiverSettings)
                }
                if airPlayReceiverEnabled {
                    LabeledContent("Status:", value: airPlayReceiverProcessManager.isRunning ? "Running" : "Stopped")
                    if let lastError = airPlayReceiverProcessManager.lastError {
                        Text("\(lastError)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("AirPlay Receiver")
            } footer: {
                Text("Only one AirPlay receiver can be active on this Mac at a time — macOS's own built-in one (System Settings → General → AirDrop & Handoff), ControlBooth's, or this one — since all of them use RTSP port 5000. Enabling it here just starts capture; it keeps receiving in the background even while another source (radio tuning, a device, etc.) is playing. Use the AirPlay Listen button in the web UI to route its audio to the live stream — switching to a different source only stops listening to it, not the capture itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Show Config Files in Finder") {
                        showConfigFilesInFinder()
                    }
                    Spacer()
                    Button("Change Configuration…") {
                        showingEditSheet = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadSettings)
        .sheet(isPresented: $showingEditSheet, onDismiss: reloadSettings) {
            EditConfigurationSheet(ports: PortSettings.load(), outputBitrate: outputBitrate)
        }
    }

    private func portRow(_ label: String, _ port: Int) -> some View {
        LabeledContent(label) {
            Text(String(port))
                .monospacedDigit()
        }
    }

    private func httpsPortRow(_ label: String, _ port: Int) -> some View {
        LabeledContent(label) {
            if httpServer.httpsEnabled {
                Text(String(port))
                    .monospacedDigit()
            } else {
                Text("(Not enabled)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reloadSettings() {
        outputBitrate = AntennaHeadHTTPServer.storedOutputBitrate(sqlite: .shared)
        streamingHTTPSPort = PortSettings.load().streamingHTTPS
        let enabled = (try? SQLiteController.shared.appSettingsValue(forKey: Self.controlBoothEnabledKey)) ?? nil
        controlBoothEnabled = enabled == "1"
        var resolvedFromBookmark = false
        if let base64 = (try? SQLiteController.shared.appSettingsValue(forKey: Self.controlBoothBookmarkKey)) ?? nil,
           let data = Data(base64Encoded: base64) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &isStale) {
                controlBoothAppPath = url.path
                resolvedFromBookmark = true
                if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                               includingResourceValuesForKeys: nil,
                                                               relativeTo: nil) {
                    try? SQLiteController.shared.storeAppSettingsValue(
                        fresh.base64EncodedString(), forKey: Self.controlBoothBookmarkKey)
                }
            }
        }
        if !resolvedFromBookmark {
            let storedPath = (try? SQLiteController.shared.appSettingsValue(forKey: Self.controlBoothPathKey)) ?? nil
            controlBoothAppPath = storedPath.flatMap { $0.isEmpty ? nil : $0 } ?? "/Applications/ControlBooth.app"
        }
        let autoLaunch = (try? SQLiteController.shared.appSettingsValue(forKey: Self.controlBoothAutoLaunchKey)) ?? nil
        launchControlBoothOnStartup = autoLaunch == "1"
        let airPlayEnabled = (try? SQLiteController.shared.appSettingsValue(forKey: Self.airPlayReceiverEnabledKey)) ?? nil
        airPlayReceiverEnabled = airPlayEnabled == "1"
        let storedDeviceName = (try? SQLiteController.shared.appSettingsValue(forKey: Self.airPlayReceiverDeviceNameKey)) ?? nil
        airPlayReceiverDeviceName = storedDeviceName ?? "AntennaHead"
    }

    private func saveControlBoothSettings() {
        try? SQLiteController.shared.storeAppSettingsValue(
            controlBoothEnabled ? "1" : "0", forKey: Self.controlBoothEnabledKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            controlBoothAppPath, forKey: Self.controlBoothPathKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            launchControlBoothOnStartup ? "1" : "0", forKey: Self.controlBoothAutoLaunchKey)
    }

    private func saveAirPlayReceiverSettings() {
        try? SQLiteController.shared.storeAppSettingsValue(
            airPlayReceiverEnabled ? "1" : "0", forKey: Self.airPlayReceiverEnabledKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            airPlayReceiverDeviceName, forKey: Self.airPlayReceiverDeviceNameKey)
    }

    private func chooseControlBoothApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the ControlBooth application"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controlBoothAppPath = url.path
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil) {
            try? SQLiteController.shared.storeAppSettingsValue(
                data.base64EncodedString(), forKey: Self.controlBoothBookmarkKey)
        }
        saveControlBoothSettings()
    }

    /// Opens the Application Support folder holding the database and exported
    /// TLS material — port of LocalRadio's `showConfigurationFilesButtonAction`.
    private func showConfigFilesInFinder() {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("AntennaHead", isDirectory: true) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([base])
    }
}

/// Edit sheet, mirroring LocalRadio's "Change Configuration" sheet
/// (Save / Cancel / Set Defaults): editable ports and output bitrate.
/// Saving stores everything and restarts services.
private struct EditConfigurationSheet: View {
    @State var ports: PortSettings
    @State var outputBitrate: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("AntennaHead Web Host") {
                    portField("AntennaHead Web Server HTTP Port:", $ports.webHTTP)
                    portField("AntennaHead Web Server HTTPS Port:", $ports.webHTTPS)
                    portField("Streaming Server HTTP Port:", $ports.streamingHTTP)
                    portField("Streaming Server HTTPS Port:", $ports.streamingHTTPS)
                }
                Section("Other Ports") {
                    portField("Status Port (UDP):", $ports.statusUDP)
                    portField("Audio Port (UDP):", $ports.audioUDP)
                }
                Section("AAC Settings") {
                    Picker("Bitrate:", selection: $outputBitrate) {
                        ForEach(AntennaHeadHTTPServer.outputBitrateOptions, id: \.self) { bps in
                            Text("\(bps / 1000) kbps").tag(bps)
                        }
                    }
                }
                Section {
                    Text("Saving restarts the streaming servers, which interrupts web audio players.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Set Defaults") {
                    ports = .default
                    outputBitrate = AntennaHeadHTTPServer.defaultOutputBitrate
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!portsAreValid)
            }
            .padding()
        }
        .frame(width: 460, height: 480)
    }

    private func portField(_ label: String, _ value: Binding<UInt16>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
    }

    /// All ports non-zero and mutually distinct (each needs its own listener).
    private var portsAreValid: Bool {
        let all = [ports.webHTTP, ports.webHTTPS, ports.streamingHTTP, ports.streamingHTTPS,
                   ports.statusUDP, ports.audioUDP]
        return all.allSatisfy { $0 > 0 } && Set(all).count == all.count
    }

    private func save() {
        ports.store()
        try? SQLiteController.shared.storeAppSettingsValue(
            "\(outputBitrate)", forKey: AntennaHeadHTTPServer.outputBitrateConfigKey)
        // ContentView observes this and restarts services with the new settings.
        NotificationCenter.default.post(
            name: AntennaHeadHTTPServer.settingsDidChangeNotification, object: nil)
    }
}
