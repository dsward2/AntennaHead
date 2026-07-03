import SwiftUI

/// Configuration tab, mirroring LocalRadio's Configuration tab: grouped boxes
/// showing the web-host ports, helper ports, and AAC settings, plus
/// "Show Config Files in Finder" and a "Change Configuration…" edit sheet.
/// Ports are fixed constants in AntennaHead, so only the output bitrate is
/// editable; saving restarts services via `settingsDidChangeNotification`.
struct ConfigurationView: View {
    var httpServer: AntennaHeadHTTPServer
    var lasProcess: LiveAudioServerProcessManager
    var sdrController: SDRController

    @State private var outputBitrate = AntennaHeadHTTPServer.defaultOutputBitrate
    /// LAS doesn't expose its TLS port, so show the configured value.
    @State private var streamingHTTPSPort = PortSettings.default.streamingHTTPS
    @State private var showingEditSheet = false

    var body: some View {
        Form {
            Section("AntennaHead Web Host") {
                portRow("AntennaHead Web Server HTTP Port:", Int(httpServer.httpPort))
                if httpServer.httpsEnabled {
                    portRow("AntennaHead Web Server HTTPS Port:", Int(httpServer.httpsPort))
                }
                portRow("Streaming Server HTTP Port:", lasProcess.httpPort)
                if httpServer.httpsEnabled {
                    portRow("Streaming Server HTTPS Port:", Int(streamingHTTPSPort))
                }
            }

            Section("Other Ports") {
                portRow("Status Port (UDP):", Int(sdrController.statusUDPPort))
                portRow("Audio Port (UDP):", Int(sdrController.udpInputPort))
            }

            Section("AAC Settings") {
                LabeledContent("Bitrate:") {
                    Text("\(outputBitrate / 1000) kbps")
                        .monospacedDigit()
                }
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

    private func reloadSettings() {
        outputBitrate = AntennaHeadHTTPServer.storedOutputBitrate(sqlite: .shared)
        streamingHTTPSPort = PortSettings.load().streamingHTTPS
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
        try? SQLiteController.shared.storeLocalRadioAppSettingsValue(
            "\(outputBitrate)", forKey: AntennaHeadHTTPServer.outputBitrateConfigKey)
        // ContentView observes this and restarts services with the new settings.
        NotificationCenter.default.post(
            name: AntennaHeadHTTPServer.settingsDidChangeNotification, object: nil)
    }
}
