import AVFoundation
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

    @State private var outputBitrate = AntennaHeadHTTPServer.defaultOutputBitrate
    /// LAS doesn't expose its TLS port, so show the configured value.
    @State private var streamingHTTPSPort = PortSettings.default.streamingHTTPS
    @State private var showingEditSheet = false
    @State private var controlBoothEnabled = false
    @State private var controlBoothAppPath = "/Applications/ControlBooth.app"
    @State private var launchControlBoothOnStartup = false
    @State private var announcementEnabled = false
    @State private var announcementVoiceID = ""
    @State private var previewSynth = AVSpeechSynthesizer()
    @State private var transcriptionEnabled = false
    @State private var transcriptionLocale = "en-US"
    @State private var transcriptionSavesTranscript = false
    @State private var spatialAudioEnabled = false
    @State private var fillerEnabled = true
    @State private var fillerFadeEnabled = true
    @State private var fillerFadeMs = 700
    @State private var fillerUsesCustomSource = false
    @State private var fillerShuffle = false
    @State private var fillerGapSeconds = 0
    @State private var fillerSyncMessage = ""
    @State private var fillerAnnounceEnabled = false
    @State private var fillerAnnounceText = SDRController.defaultFillerAnnounceText
    @State private var fillerAnnounceVoiceID = ""
    @State private var fillerAnnouncePeriodSeconds = 60

    /// System speech voices, sorted by language then name, for the announcement
    /// picker. Only installed voices are returned, so the menu is self-limiting.
    private let installedVoices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .sorted { ($0.language, $0.name) < ($1.language, $1.name) }

    private static let controlBoothEnabledKey = "AntennaHeadControlBoothEnabled"
    static let controlBoothPathKey = "AntennaHeadControlBoothAppPath"
    static let controlBoothAutoLaunchKey = "AntennaHeadControlBoothAutoLaunch"
    static let controlBoothBookmarkKey = "AntennaHeadControlBoothBookmark"

    var body: some View {
        Form {
            Section("AntennaHead Web Host") {
                portRow("AntennaHead Web Server HTTP Port:", Int(httpServer.httpPort))
                httpsPortRow("AntennaHead Web Server HTTPS Port:", Int(httpServer.httpsPort))
                portRow("Streaming Server HTTP Port:", lasProcess.httpPort)
                httpsPortRow("Streaming Server HTTPS Port:", Int(streamingHTTPSPort))
                if let lastError = httpServer.lastError {
                    Text(lastError.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Other Ports") {
                portRow("Status Port (UDP):", Int(sdrController.statusUDPPort))
                portRow("Audio Port (UDP):", Int(sdrController.udpInputPort))
                portRow("ControlBooth Receive Port (UDP):", Int(sdrController.controlBoothReceivePort))
            }

            Section("AAC Settings") {
                LabeledContent("Bitrate:") {
                    Text("\(outputBitrate / 1000) kbps")
                        .monospacedDigit()
                }
            }

            Section {
                Toggle("Announce the station before playback", isOn: $announcementEnabled)
                    .onChange(of: announcementEnabled) { _, _ in saveAnnouncementSettings() }
                Picker("Voice", selection: $announcementVoiceID) {
                    Text("System Default").tag("")
                    ForEach(installedVoices, id: \.identifier) { voice in
                        Text(voiceLabel(voice)).tag(voice.identifier)
                    }
                }
                .onChange(of: announcementVoiceID) { _, _ in saveAnnouncementSettings() }
                .disabled(!announcementEnabled)
                HStack {
                    Button("Preview Voice") { previewAnnouncementVoice() }
                        .disabled(!announcementEnabled)
                    Spacer()
                }
            } header: {
                Text("Announcements")
            } footer: {
                Text("When enabled, a synthesized voice says \u{201C}Now playing \u{2026}\u{201D} \u{2014} the station name, plus the frequency and band for a fixed tuning \u{2014} before a Favorite or category scan starts. Only voices installed on this Mac are listed; add more in System Settings \u{203A} Accessibility \u{203A} Spoken Content \u{203A} System Voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Transcribe the audio (on-device speech recognition)", isOn: $transcriptionEnabled)
                    .onChange(of: transcriptionEnabled) { _, _ in saveTranscriptionSettings() }
                TextField("Language", text: $transcriptionLocale, prompt: Text("en-US"))
                    .onSubmit { saveTranscriptionSettings() }
                    .disabled(!transcriptionEnabled)
                Toggle("Also save an SRT transcript to the Recordings folder", isOn: $transcriptionSavesTranscript)
                    .onChange(of: transcriptionSavesTranscript) { _, _ in saveTranscriptionSettings() }
                    .disabled(!transcriptionEnabled)
            } header: {
                Text("Speech-to-Text")
            } footer: {
                Text("Runs a \u{201C}PCMTranscriber\u{201D} tap on the outgoing audio using Apple\u{2019}s on-device SpeechAnalyzer (requires macOS 26). Recognition results stream as JSON on UDP port \(Int(sdrController.transcriptionUDPPort)) for a caption client; the optional SRT file lands in the shared Recordings folder. Broadcast audio \u{2014} music, weak FM, overlapping speech \u{2014} transcribes unevenly. Language is a BCP-47 code such as \u{201C}en-US\u{201D}; the model downloads once on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Spatial audio (distance + direction)", isOn: $spatialAudioEnabled)
                    .onChange(of: spatialAudioEnabled) { _, _ in saveSpatialAudioSettings() }
            } header: {
                Text("Spatial Audio")
            } footer: {
                Text("Runs \u{201C}PCMDistanceGain\u{201D} and \u{201C}PCMBinauralPanner\u{201D} taps on the outgoing audio, so the Now Playing view's Distance, Azimuth, and Elevation sliders can move the source in real time. Control messages go to UDP ports \(Int(sdrController.spatialGainControlPort)) and \(Int(sdrController.binauralControlPort)) on this Mac. Direction uses interaural time/level differences, not a measured head-related transfer function \u{2014} it localizes left/right convincingly; elevation is a mild, approximate cue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play filler audio when nothing is tuned", isOn: $fillerEnabled)
                    .onChange(of: fillerEnabled) { _, _ in saveFillerSettings() }
                Toggle("Fade in and out (rather than cut)", isOn: $fillerFadeEnabled)
                    .onChange(of: fillerFadeEnabled) { _, _ in saveFillerSettings() }
                    .disabled(!fillerEnabled)
                if fillerFadeEnabled {
                    Stepper("Fade length: \(fillerFadeMs) ms",
                            value: $fillerFadeMs, in: 100...1800, step: 100)
                        .onChange(of: fillerFadeMs) { _, _ in saveFillerSettings() }
                        .disabled(!fillerEnabled)
                }
                Toggle("Use my own audio instead of the Monitor Beacon", isOn: $fillerUsesCustomSource)
                    .onChange(of: fillerUsesCustomSource) { _, _ in saveFillerSettings() }
                    .disabled(!fillerEnabled)
                if fillerUsesCustomSource {
                    Toggle("Shuffle", isOn: $fillerShuffle)
                        .onChange(of: fillerShuffle) { _, _ in saveFillerSettings() }
                        .disabled(!fillerEnabled)
                    Stepper("Gap between tracks: \(fillerGapSeconds) s",
                            value: $fillerGapSeconds, in: 0...30)
                        .onChange(of: fillerGapSeconds) { _, _ in saveFillerSettings() }
                        .disabled(!fillerEnabled)
                    if sdrController.hasFillerSourceFolder {
                        LabeledContent("Source folder") {
                            HStack {
                                Text(sdrController.fillerSourceFolderURL()?.path ?? "\u{2014}")
                                    .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                                Button("Refresh") {
                                    fillerSyncMessage = "Copied \(sdrController.syncFillerCache()) file(s)"
                                    saveFillerSettings()
                                }
                                Button("Change\u{2026}") { chooseFillerSourceFolder() }
                                Button("Use Drop Folder") {
                                    sdrController.clearFillerSourceFolder()
                                    fillerSyncMessage = ""
                                    saveFillerSettings()
                                }
                            }
                        }
                        .disabled(!fillerEnabled)
                    } else {
                        LabeledContent("Drop folder") {
                            HStack {
                                Text(sdrController.fillerFolderURL?.path ?? "\u{2014}")
                                    .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                                if let folder = sdrController.fillerFolderURL {
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                                    }
                                }
                                Button("Choose Folder\u{2026}") { chooseFillerSourceFolder() }
                            }
                        }
                        .disabled(!fillerEnabled)
                    }
                    if !fillerSyncMessage.isEmpty {
                        Text(fillerSyncMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Filler Audio")
            } footer: {
                Text("When no station, device, or other source is active, AntennaHead loops filler audio so the stream is never silent. The built-in Monitor Beacon plays by default. For custom audio, either drop AAC / MP3 / WAV files into the \u{201C}Filler\u{201D} folder in the shared Recordings folder, or choose any folder \u{2014} its audio files are copied in and re-copied when you press Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Speak a periodic announcement over the filler", isOn: $fillerAnnounceEnabled)
                    .onChange(of: fillerAnnounceEnabled) { _, _ in saveFillerAnnounceSettings() }
                TextField("Announcement", text: $fillerAnnounceText,
                          prompt: Text(SDRController.defaultFillerAnnounceText))
                    .onSubmit { saveFillerAnnounceSettings() }
                    .disabled(!fillerAnnounceEnabled)
                Picker("Voice", selection: $fillerAnnounceVoiceID) {
                    Text("System Default").tag("")
                    ForEach(installedVoices, id: \.identifier) { voice in
                        Text(voiceLabel(voice)).tag(voice.identifier)
                    }
                }
                .onChange(of: fillerAnnounceVoiceID) { _, _ in saveFillerAnnounceSettings() }
                .disabled(!fillerAnnounceEnabled)
                Stepper("Repeat every \(fillerAnnouncePeriodSeconds) s",
                        value: $fillerAnnouncePeriodSeconds, in: 15...600, step: 5)
                    .onChange(of: fillerAnnouncePeriodSeconds) { _, _ in saveFillerAnnounceSettings() }
                    .disabled(!fillerAnnounceEnabled)
                HStack {
                    Button("Preview Voice") { previewFillerAnnounceVoice() }
                        .disabled(!fillerAnnounceEnabled)
                    Spacer()
                }
            } header: {
                Text("Filler Announcements")
            } footer: {
                Text("While the filler is playing, a synthesized voice repeats this text, mixed over the filler with the bed ducked underneath it (\u{201C}PCMMixer\u{201D} on UDP port \(Int(sdrController.fillerMixerControlPort)); the spoken audio arrives on port \(Int(sdrController.fillerAnnouncePCMPort))). The interval is measured from the end of each spoken pass, so it drifts a second or two. No effect while a station, device, or other source is playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .harmonizedFormBackground()
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
        let announceEnabled = (try? SQLiteController.shared.appSettingsValue(forKey: SDRController.announcementEnabledKey)) ?? nil
        announcementEnabled = announceEnabled == "1"
        let storedVoice = (try? SQLiteController.shared.appSettingsValue(forKey: SDRController.announcementVoiceKey)) ?? nil
        // Drop a saved voice that's no longer installed so the picker shows a valid selection.
        if let storedVoice, !storedVoice.isEmpty, AVSpeechSynthesisVoice(identifier: storedVoice) != nil {
            announcementVoiceID = storedVoice
        } else {
            announcementVoiceID = ""
        }
        let transcribeEnabled = (try? SQLiteController.shared.appSettingsValue(forKey: SDRController.transcriptionEnabledKey)) ?? nil
        transcriptionEnabled = transcribeEnabled == "1"
        let storedLocale = ((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.transcriptionLocaleKey)) ?? nil) ?? ""
        transcriptionLocale = storedLocale.isEmpty ? "en-US" : storedLocale
        let saveTranscript = (try? SQLiteController.shared.appSettingsValue(forKey: SDRController.transcriptionSaveFileKey)) ?? nil
        transcriptionSavesTranscript = saveTranscript == "1"
        let spatialEnabled = (try? SQLiteController.shared.appSettingsValue(forKey: SDRController.spatialAudioEnabledKey)) ?? nil
        spatialAudioEnabled = spatialEnabled == "1"
        // Filler defaults ON: an absent key counts as enabled.
        fillerEnabled = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerEnabledKey)) ?? nil) ?? "1") != "0"
        fillerFadeEnabled = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerFadeEnabledKey)) ?? nil) ?? "1") != "0"
        fillerFadeMs = min(max(Int((((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerFadeMsKey)) ?? nil)) ?? "") ?? 700, 100), 1800)
        fillerUsesCustomSource = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerUseCustomKey)) ?? nil)) == "1"
        fillerShuffle = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerShuffleKey)) ?? nil)) == "1"
        fillerGapSeconds = Int((((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerGapKey)) ?? nil)) ?? "") ?? 0
        // Filler announcement defaults OFF.
        fillerAnnounceEnabled = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerAnnounceEnabledKey)) ?? nil)) == "1"
        let storedAnnounceText = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerAnnounceTextKey)) ?? nil)) ?? ""
        fillerAnnounceText = storedAnnounceText.isEmpty ? SDRController.defaultFillerAnnounceText : storedAnnounceText
        let storedAnnounceVoice = (try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerAnnounceVoiceKey)) ?? nil
        if let storedAnnounceVoice, !storedAnnounceVoice.isEmpty,
           AVSpeechSynthesisVoice(identifier: storedAnnounceVoice) != nil {
            fillerAnnounceVoiceID = storedAnnounceVoice
        } else {
            fillerAnnounceVoiceID = ""
        }
        fillerAnnouncePeriodSeconds = min(max(Int((((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerAnnouncePeriodKey)) ?? nil)) ?? "") ?? 60, 15), 600)
    }

    private func saveControlBoothSettings() {
        try? SQLiteController.shared.storeAppSettingsValue(
            controlBoothEnabled ? "1" : "0", forKey: Self.controlBoothEnabledKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            controlBoothAppPath, forKey: Self.controlBoothPathKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            launchControlBoothOnStartup ? "1" : "0", forKey: Self.controlBoothAutoLaunchKey)
    }

    private func saveAnnouncementSettings() {
        try? SQLiteController.shared.storeAppSettingsValue(
            announcementEnabled ? "1" : "0", forKey: SDRController.announcementEnabledKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            announcementVoiceID, forKey: SDRController.announcementVoiceKey)
    }

    private func saveTranscriptionSettings() {
        let locale = transcriptionLocale.trimmingCharacters(in: .whitespaces)
        if locale.isEmpty { transcriptionLocale = "en-US" }
        try? SQLiteController.shared.storeAppSettingsValue(
            transcriptionEnabled ? "1" : "0", forKey: SDRController.transcriptionEnabledKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            locale.isEmpty ? "en-US" : locale, forKey: SDRController.transcriptionLocaleKey)
        try? SQLiteController.shared.storeAppSettingsValue(
            transcriptionSavesTranscript ? "1" : "0", forKey: SDRController.transcriptionSaveFileKey)
    }

    private func saveSpatialAudioSettings() {
        try? SQLiteController.shared.storeAppSettingsValue(
            spatialAudioEnabled ? "1" : "0", forKey: SDRController.spatialAudioEnabledKey)
    }

    private func saveFillerSettings() {
        let s = SQLiteController.shared
        try? s.storeAppSettingsValue(fillerEnabled ? "1" : "0", forKey: SDRController.fillerEnabledKey)
        try? s.storeAppSettingsValue(fillerFadeEnabled ? "1" : "0", forKey: SDRController.fillerFadeEnabledKey)
        try? s.storeAppSettingsValue("\(fillerFadeMs)", forKey: SDRController.fillerFadeMsKey)
        try? s.storeAppSettingsValue(fillerUsesCustomSource ? "1" : "0", forKey: SDRController.fillerUseCustomKey)
        try? s.storeAppSettingsValue(fillerShuffle ? "1" : "0", forKey: SDRController.fillerShuffleKey)
        try? s.storeAppSettingsValue("\(fillerGapSeconds)", forKey: SDRController.fillerGapKey)
        sdrController.fillerSettingsDidChange()
    }

    private func saveFillerAnnounceSettings() {
        let s = SQLiteController.shared
        let text = fillerAnnounceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { fillerAnnounceText = SDRController.defaultFillerAnnounceText }
        try? s.storeAppSettingsValue(fillerAnnounceEnabled ? "1" : "0", forKey: SDRController.fillerAnnounceEnabledKey)
        try? s.storeAppSettingsValue(text, forKey: SDRController.fillerAnnounceTextKey)
        try? s.storeAppSettingsValue(fillerAnnounceVoiceID, forKey: SDRController.fillerAnnounceVoiceKey)
        try? s.storeAppSettingsValue("\(fillerAnnouncePeriodSeconds)", forKey: SDRController.fillerAnnouncePeriodKey)
        sdrController.fillerSettingsDidChange()
    }

    private func previewFillerAnnounceVoice() {
        previewSynth.stopSpeaking(at: .immediate)
        let trimmed = fillerAnnounceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let utterance = AVSpeechUtterance(string: trimmed.isEmpty ? SDRController.defaultFillerAnnounceText : trimmed)
        if !fillerAnnounceVoiceID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: fillerAnnounceVoiceID)
        }
        previewSynth.speak(utterance)
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .enhanced: quality = " (Enhanced)"
        case .premium: quality = " (Premium)"
        default: quality = ""
        }
        return "\(voice.name) — \(voice.language)\(quality)"
    }

    private func previewAnnouncementVoice() {
        previewSynth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Now playing K U A R. 89.1 F M.")
        if !announcementVoiceID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: announcementVoiceID)
        }
        previewSynth.speak(utterance)
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

    private func chooseFillerSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of audio files to use as filler"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let copied = sdrController.setFillerSourceFolder(url)
        fillerSyncMessage = "Copied \(copied) file(s)"
        saveFillerSettings()
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
                    portField("ControlBooth Receive Port (UDP):", $ports.controlBoothUDP)
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
            .scrollContentBackground(.hidden)

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
        .background(Color.appBackground)
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
                   ports.statusUDP, ports.audioUDP, ports.controlBoothUDP]
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
