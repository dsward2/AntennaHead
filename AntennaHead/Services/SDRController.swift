import AVFoundation
import Foundation
import Observation
import PipelineRunner
import SharedLogging

/// Builds and drives the RTL-SDR audio pipeline, ported from LocalRadio's
/// Objective-C `SDRController`.
///
/// The pipeline is assembled with `TaskPipelineManager` and terminates in a
/// `PCMUDPSender` stage that forwards PCM to the continuously-running
/// LiveAudioServer over UDP. Because LiveAudioServer is decoupled (see
/// `LiveAudioServerProcessManager`), retuning only rebuilds this pipeline — the
/// listener's HTTP audio connection is never dropped.
///
///     rtl_fm_localradio  ->  sox (resample to S16LE mono 48k + filter)  ->  PCMUDPSender  --udp-->  LiveAudioServer
///
/// Core Audio device input, custom-task input, FM-stereo demux, and the rtl_fm
/// status/signal-level UDP port are deferred to later sub-phases.
@MainActor
@Observable
final class SDRController {
    enum TaskMode: String {
        case stopped
        case frequency
        case scan
        case device
        case customTask
        case recording
    }

    enum SDRError: Error, CustomStringConvertible {
        case frequencyNotFound(Int64)
        case categoryNotFound(Int64)
        case categoryHasNoFrequencies(Int64)
        case recordingNotFound(String)
        case notImplemented(String)

        var description: String {
            switch self {
            case .frequencyNotFound(let id): return "No frequency record found for id \(id)."
            case .categoryNotFound(let id): return "No category record found for id \(id)."
            case .categoryHasNoFrequencies(let id): return "Category \(id) has no frequencies to scan."
            case .recordingNotFound(let name): return "Recording '\(name)' was not found in the shared Recordings folder."
            case .notImplemented(let what): return "\(what) is not yet implemented."
            }
        }
    }

    // Output format of the pipeline's terminal stage; must match LiveAudioServer's
    // UDP input configuration (see LiveAudioServerProcessManager).
    private static let outputSampleRate = 48_000
    // The pipeline always emits 2-channel audio so LiveAudioServer's UDP input
    // format stays constant across retunes (mono stations are upmixed to
    // dual-mono; FM-stereo stations decode true L/R via stereodemux).
    private static let outputChannels = 2

    private let sqliteController: SQLiteController
    /// UDP port the terminal PCMUDPSender stage targets (LiveAudioServer's input).
    /// Configurable via `updatePorts`; used when the next pipeline is built.
    private(set) var udpInputPort: UInt16
    /// Local UDP port rtl_fm's `-c` status feed (frequency + RMS signal level)
    /// is sent to, captured by `statusListener`. Shown on the Configuration tab.
    private(set) var statusUDPPort: UInt16
    /// UDP port PCMUDPReceiver listens on for PCM datagrams from ControlBooth.
    private(set) var controlBoothReceivePort: UInt16 = 6019
    /// UDP port PCMUDPReceiver listens on for Gqrx's 2-channel PCM audio
    /// output — Gqrx's own default UDP audio port (see NETWORK_PORTS.md). Not
    /// exposed in the Configuration sheet like the other ports, but surfaced
    /// read-only in the "Listen to Gqrx" web UI.
    let gqrxReceivePort: UInt16 = 7355
    /// UDP port the optional `PCMTranscriber` tap sends newline-delimited
    /// speech-recognition JSON to (`{"type":"partial"|"final","text":…,
    /// "start":…,"end":…}`), for an in-app listener to surface as live captions.
    /// Fixed like `gqrxReceivePort`; not exposed in the Configuration sheet.
    let transcriptionUDPPort: UInt16 = 6023
    private var statusListener: RTLSDRStatusListener?
    private var captionListener: TranscriptionCaptionListener?

    /// One text file picked in the "Text to Speech" web UI. The browser reads
    /// the folder and posts these; `startTextToSpeech` orders them, concatenates
    /// the text, and feeds it to PCMSpeechSynth.
    struct SpeechTextFile {
        let name: String
        let modified: Date
        let text: String
    }

    /// Sample rate PCMSpeechSynth is told to emit for the Text-to-Speech
    /// pipeline; the downstream sox stage resamples it to the 48 kHz / 2 ch
    /// LiveAudioServer contract.
    private static let speechSynthSampleRate = 22_050

    /// Combined-text temp file staged for the running PCMSpeechSynth stage, if
    /// any. Deleted when the next pipeline starts or all tasks are stopped.
    private var speechSynthTextFileURL: URL?

    // MARK: Speech-to-text tap

    /// App-settings keys for the optional `PCMTranscriber` stage that runs
    /// on-device speech recognition on the outgoing audio. Read fresh each time
    /// a pipeline is built, and edited in the Configuration view.
    static let transcriptionEnabledKey = "AntennaHeadTranscriptionEnabled"
    static let transcriptionLocaleKey = "AntennaHeadTranscriptionLocale"
    static let transcriptionSaveFileKey = "AntennaHeadTranscriptionSaveTranscript"

    /// Whether the speech-to-text tap is switched on in Configuration.
    var transcriptionEnabled: Bool {
        ((try? sqliteController.appSettingsValue(forKey: Self.transcriptionEnabledKey)) ?? nil) == "1"
    }

    /// BCP-47 locale `PCMTranscriber` recognizes in; defaults to `en-US`.
    private var transcriptionLocale: String {
        let stored = ((try? sqliteController.appSettingsValue(forKey: Self.transcriptionLocaleKey)) ?? nil) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "en-US" : trimmed
    }

    /// Whether the tap also appends an SRT transcript to the shared Recordings
    /// folder (in addition to the always-on `transcriptionUDPPort` caption feed).
    private var transcriptionSavesFile: Bool {
        ((try? sqliteController.appSettingsValue(forKey: Self.transcriptionSaveFileKey)) ?? nil) == "1"
    }

    /// The SRT transcript being written for the current pipeline, if any. Unlike
    /// the speech-synth temp file this is a user artifact — left in the
    /// Recordings folder when the pipeline stops, only the reference is cleared.
    private var transcriptFileURL: URL?

    /// Timestamp fragment for transcript filenames (sortable, filename-safe).
    private static let transcriptTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    // MARK: Spoken station announcement

    /// App-settings keys for the optional voice that says "Now playing …" before
    /// a tuning starts. Read fresh each time a pipeline is built, and edited in
    /// the Configuration view.
    static let announcementEnabledKey = "AntennaHeadAnnouncementEnabled"
    static let announcementVoiceKey = "AntennaHeadAnnouncementVoiceIdentifier"

    /// Whether the spoken announcement is switched on in Configuration.
    var announcementEnabled: Bool {
        ((try? sqliteController.appSettingsValue(forKey: Self.announcementEnabledKey)) ?? nil) == "1"
    }

    /// The announcement clip rendered for the current pipeline, if any. Deleted
    /// when the next pipeline starts or all tasks are stopped.
    private var announcementClipURL: URL?

    /// PCMSpeechSynth renders the announcement at this rate/format; PCMPrefix
    /// plays it (up-mixing mono → stereo) with no resampling, so it must match
    /// the LiveAudioServer contract rate.
    private static let announcementRenderRate = 48_000

    /// One announcement queued for the deferred pipeline launch: the text to
    /// speak, the chosen voice (nil = system default), and where PCMSpeechSynth
    /// should write the clip that the already-added PCMPrefix stage will read.
    private struct PendingAnnouncement: Sendable {
        let text: String
        let voiceIdentifier: String?
        let clipURL: URL
    }

    let radioTaskPipelineManager = TaskPipelineManager()
    /// Pending async pipeline launch; cancelled and replaced whenever a new
    /// pipeline is requested before the previous one has fully started.
    private var pipelineStartTask: Task<Void, Never>?

    // MARK: Published status (replaces LocalRadio's AppKit IBOutlet status fields)

    private(set) var taskMode: TaskMode = .stopped
    /// The frequency record id currently tuned (frequency mode), else nil.
    /// Lets the UI show which station is live.
    private(set) var activeFrequencyID: Int64?
    private(set) var statusFunction: String = "No active tuning"
    private(set) var stationName: String = ""
    private(set) var frequencyDisplay: String = ""
    private(set) var modulation: String = ""
    private(set) var sampleRate: Int = 0
    private(set) var tunerGain: Double = 0
    private(set) var squelchLevel: Int = 0
    private(set) var options: String = ""
    private(set) var audioOutputFilter: String = ""
    private(set) var tunerAGC: Bool = false
    private(set) var directSamplingQBranch: Bool = false
    /// Latest RMS signal level reported by rtl_fm (raw, matches LocalRadio's
    /// "signal level" display). Zero when no tuner is running.
    private(set) var signalLevel: Int = 0

    /// Identity of the RTL-SDR dongle feeding the active frequency tuning,
    /// resolved once at tune time. librtlsdr can't read a device's EEPROM
    /// strings once rtl_fm has it open, so these are captured in the brief
    /// window after the previous pipeline is torn down and before the new one
    /// launches (see `resolveActiveDevice`). `activeDeviceSerial` is "" when the
    /// dongle carries no EEPROM serial; `activeDeviceIndex` is -1 when the
    /// configured device isn't currently connected. Cleared by `terminateTasks`;
    /// left untouched by the non-tuner sources (device input, recordings,
    /// ControlBooth/AirPlay bridges), whose Now Playing view shows no tuner rows.
    private(set) var activeDeviceSerial: String = ""
    private(set) var activeDeviceIndex: Int = -1

    /// Demodulated audio channel count for the active tuning: 2 when FM-stereo
    /// decoding is engaged, otherwise 1. (LiveAudioServer always emits 2 ch.)
    private(set) var activeChannelCount: Int = 0

    /// USB index → EEPROM serial, accumulated across tunes. Once a dongle's
    /// serial has been read it is kept here: a later enumeration while rtl_fm
    /// holds the device open returns a blank serial, and `resolveActiveDevice`
    /// falls back to this cache.
    private var deviceSerialByIndex: [UInt32: String] = [:]

    /// Most recent not-yet-final caption hypothesis from the `PCMTranscriber`
    /// tap, or "" when there is none pending. Cleared when it finalizes and
    /// whenever a pipeline is (re)built or stopped.
    private(set) var liveCaption: String = ""
    /// Finalized caption segments for the current listening session, oldest
    /// first, capped at `captionHistoryLimit`. Reset on each retune.
    private(set) var captionHistory: [String] = []
    private static let captionHistoryLimit = 200
    /// Monotonic count of finalized caption segments for the current session.
    /// `captionHistory.count` plateaus at `captionHistoryLimit` once the ring
    /// fills, so a polling client can't use it to spot new finals after that;
    /// this keeps advancing. Reset with the history on each retune.
    private(set) var captionSeq: Int = 0

    private(set) var lastError: Error?

    init(sqliteController: SQLiteController? = nil, udpInputPort: UInt16, statusUDPPort: UInt16 = 6021) {
        self.sqliteController = sqliteController ?? .shared
        self.udpInputPort = udpInputPort
        self.statusUDPPort = statusUDPPort
        radioTaskPipelineManager.onLog = { source, message in
            LogStore.shared.log(.info, source: source, message)
        }
        startStatusListener()
        startCaptionListener()
    }

    /// Applies the configured UDP ports (Configuration sheet). The audio port
    /// takes effect when the next pipeline is built; a changed status port
    /// recreates the rtl_fm status listener immediately.
    func updatePorts(udpInput: UInt16, statusUDP: UInt16, controlBoothReceive: UInt16 = 6019) {
        udpInputPort = udpInput
        controlBoothReceivePort = controlBoothReceive
        guard statusUDP != statusUDPPort else { return }
        statusUDPPort = statusUDP
        statusListener?.stop()
        startStatusListener()
    }

    private func startStatusListener() {
        statusListener = RTLSDRStatusListener(port: statusUDPPort)
        statusListener?.onRMSPower = { [weak self] rms in
            guard let self else { return }
            Task { @MainActor in self.signalLevel = rms }
        }
        statusListener?.start()
    }

    /// Starts the always-on listener for the `PCMTranscriber` tap's caption
    /// feed on `transcriptionUDPPort`. Runs for the lifetime of the controller
    /// (the port is fixed); it simply sees no traffic when no tap is active.
    private func startCaptionListener() {
        captionListener = TranscriptionCaptionListener(port: transcriptionUDPPort)
        captionListener?.onCaption = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.applyCaption(event) }
        }
        captionListener?.start()
    }

    @MainActor private func applyCaption(_ event: CaptionEvent) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch event.kind {
        case .partial:
            liveCaption = text
        case .final:
            liveCaption = ""
            guard !text.isEmpty else { return }
            captionHistory.append(text)
            captionSeq &+= 1
            if captionHistory.count > Self.captionHistoryLimit {
                captionHistory.removeFirst(captionHistory.count - Self.captionHistoryLimit)
            }
        }
    }

    /// Clears the caption display + transcript. Called whenever a pipeline is
    /// (re)built or all tasks stop, so captions never carry across sources.
    private func resetCaptions() {
        liveCaption = ""
        captionHistory.removeAll()
        captionSeq = 0
    }

    // MARK: Public control API (ported from SDRController.h)

    /// Tune to a single saved frequency ("favorite").
    func startTasksForFrequency(id: Int64) throws {
        guard let frequency = try sqliteController.frequencyRecord(forID: id) else {
            throw SDRError.frequencyNotFound(id)
        }
        let tuning = makeTuning(forFrequency: frequency)
        taskMode = .frequency
        activeFrequencyID = id
        startPipeline(with: tuning)
    }

    /// Tune to an ad-hoc frequency from the web Tuner (no saved record). Builds a
    /// one-off `Frequency` from the prototype defaults plus the tuner's chosen
    /// parameters, then drives the normal pipeline (stereodemux is inserted when
    /// `modulation == "fm"` and `stereo`). `usbDevice` is the RTL-SDR USB device
    /// index or EEPROM serial number from the Tuner's "USB Device" field; empty
    /// falls back to device 0 (see `makeTuning`).
    func startTasksForFrequency(frequencyHz: Int, sampleRate: Int, tunerGain: Double,
                                stereo: Bool, modulation: String, usbDevice: String = "") {
        var f = Frequency.prototype()
        f.frequency = frequencyHz
        f.sampleRate = sampleRate
        f.tunerGain = tunerGain
        f.stereoFlag = stereo
        f.modulation = modulation.isEmpty ? "fm" : modulation
        f.usbDeviceString = usbDevice
        f.stationName = String(format: "%.4f MHz", Double(frequencyHz) / 1_000_000.0)
        let tuning = makeTuning(forFrequency: f)
        taskMode = .frequency
        activeFrequencyID = nil   // ad-hoc: not a saved favorite
        startPipeline(with: tuning)
    }

    /// Scan all frequencies belonging to a category.
    func startTasksForCategoryScan(id: Int64) throws {
        guard let category = try sqliteController.categoryRecord(forID: id) else {
            throw SDRError.categoryNotFound(id)
        }
        let frequencies = try sqliteController.allFrequencyRecords(forCategoryID: id)
        guard !frequencies.isEmpty else {
            throw SDRError.categoryHasNoFrequencies(id)
        }
        let tuning = makeTuning(forCategory: category, frequencies: frequencies)
        taskMode = .scan
        activeFrequencyID = nil
        startPipeline(with: tuning)
    }

    /// Listen to a Core Audio input device. The `AudioInputCapture` helper
    /// captures the named device and emits 48 kHz / 2-channel S16LE (the
    /// LiveAudioServer contract), so sox only applies the output filter.
    func startTasksForDevice(deviceName: String, deviceAudioOutputFilter: String) {
        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()

        taskMode = .device
        activeFrequencyID = nil
        publishDeviceStatus(deviceName: deviceName, filter: deviceAudioOutputFilter)

        let capture = makeAudioCaptureTaskItem(deviceName: deviceName)
        // Capture already outputs 48 kHz / 2-channel, so this sox stage is a
        // no-op resample that just applies the station's audio filter tokens.
        let resample = makeResampleTaskItem(inputRate: Self.outputSampleRate,
                                            inputChannels: Self.outputChannels,
                                            audioOutputFilter: deviceAudioOutputFilter)
        let udpSender = makeUDPSenderTaskItem()

        guard let capture, let resample, let udpSender else {
            taskMode = .stopped
            return  // lastError already set by the failing builder
        }

        // Optional spoken "Now playing …" clip. `drop` mode: the live capture
        // source keeps running and its first ~clip-length of audio is discarded
        // rather than stalling.
        let announcement = prepareAnnouncement(text: Self.announcementText(forDevice: deviceName),
                                               holdInput: false)

        radioTaskPipelineManager.add(capture)
        radioTaskPipelineManager.add(resample)
        if let announcement { radioTaskPipelineManager.add(announcement.stage) }
        addTranscriberStageIfEnabled()
        radioTaskPipelineManager.add(udpSender)

        launchCurrentPipeline(dying: dying, announcement: announcement?.pending)
    }

    /// Listen to a recorded audio file from the shared App Group Recordings
    /// folder (see `SharedRecordingFolder`) via the `PCMFilePlayer` helper.
    /// That helper decodes straight to the 48 kHz / 2 ch LiveAudioServer
    /// contract, so — like the ControlBooth/AirPlay bridges — no sox resample
    /// stage is needed here.
    ///
    /// `fileName` must be a bare filename (no path separators): it's resolved
    /// against the Recordings folder here rather than trusting a path the web
    /// UI sent, so a tampered request can't reach outside that folder.
    func startTasksForRecording(fileName: String, repeatAudio: Bool) throws {
        guard !fileName.isEmpty, !fileName.contains("/") else {
            throw SDRError.recordingNotFound(fileName)
        }
        guard let folder = SharedRecordingFolder.url else {
            throw SDRError.notImplemented("The shared Recordings folder")
        }
        let fileURL = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SDRError.recordingNotFound(fileName)
        }

        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()

        taskMode = .recording
        activeFrequencyID = nil
        publishRecordingStatus(fileName: fileName, repeatAudio: repeatAudio)

        guard let player = makeFilePlayerTaskItem(fileURL: fileURL, repeatAudio: repeatAudio),
              let udpSender = makeUDPSenderTaskItem() else {
            taskMode = .stopped
            return
        }

        // Optional spoken "Now playing …" clip. `hold` mode: PCMFilePlayer is
        // self-pacing, so hold its output until the clip finishes and it plays
        // the recording from the start rather than dropping the opening audio.
        let announcement = prepareAnnouncement(text: Self.announcementText(forRecording: fileName),
                                               holdInput: true)

        radioTaskPipelineManager.add(player)
        if let announcement { radioTaskPipelineManager.add(announcement.stage) }
        addTranscriberStageIfEnabled()
        radioTaskPipelineManager.add(udpSender)

        launchCurrentPipeline(dying: dying, announcement: announcement?.pending)
    }

    private func makeFilePlayerTaskItem(fileURL: URL, repeatAudio: Bool) -> TaskItem? {
        let path = helperPath("PCMFilePlayer")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastError = SDRError.notImplemented("PCMFilePlayer helper missing at \(path)")
            LogStore.shared.log(.error, source: "SDRController", "PCMFilePlayer helper missing at \(path)")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path, functionName: "PCMFilePlayer")
        item.addArgument("--file"); item.addArgument(fileURL.path)
        item.addArgument("--rate"); item.addArgument(Self.outputSampleRate)
        item.addArgument("--channels"); item.addArgument(Self.outputChannels)
        if repeatAudio {
            item.addArgument("--repeat")
            item.addArgument("--gap"); item.addArgument(2)
        }
        item.addArgument("--exit-with-parent")
        return item
    }

    private func publishRecordingStatus(fileName: String, repeatAudio: Bool) {
        statusFunction = "Playing Recording" + (repeatAudio ? " (repeating)" : "")
        stationName = fileName
        modulation = ""
        frequencyDisplay = ""
        sampleRate = Self.outputSampleRate
        tunerGain = 0
        squelchLevel = 0
        options = ""
        audioOutputFilter = ""
        tunerAGC = false
        directSamplingQBranch = false
    }

    /// Start a PCMUDPReceiver → PCMUDPSender bridge pipeline that receives PCM
    /// datagrams from ControlBooth on `controlBoothReceivePort` and relays them
    /// to LiveAudioServer on `udpInputPort`. Also updates published status so
    /// the UI reflects that ControlBooth is the active source.
    func startControlBoothListening(name: String) {
        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()
        taskMode = .customTask
        activeFrequencyID = nil
        statusFunction = "ControlBooth: \(name)"
        stationName = name
        modulation = ""
        frequencyDisplay = ""
        sampleRate = Self.outputSampleRate
        tunerGain = 0
        squelchLevel = 0
        options = ""
        audioOutputFilter = ""
        tunerAGC = false
        directSamplingQBranch = false
        lastError = nil

        guard let receiver = makeUDPReceiverTaskItem(port: controlBoothReceivePort),
              let sender = makeUDPSenderTaskItem() else { return }

        // Optional spoken "Now playing …" clip. `drop` mode: the ControlBooth
        // UDP feed keeps arriving and its first ~clip-length of audio is
        // discarded rather than stalling the bridge.
        let announcement = prepareAnnouncement(text: Self.announcementText(forControlBooth: name),
                                               holdInput: false)

        radioTaskPipelineManager.add(receiver)
        if let announcement { radioTaskPipelineManager.add(announcement.stage) }
        addTranscriberStageIfEnabled()
        radioTaskPipelineManager.add(sender)
        launchCurrentPipeline(dying: dying, waitForDyingProcesses: false,
                              announcement: announcement?.pending)
    }

    /// Start a PCMUDPReceiver → sox → PCMUDPSender bridge pipeline that receives
    /// Gqrx's UDP audio output on `gqrxReceivePort`, normalizes it to the
    /// LiveAudioServer 48 kHz/2ch contract via sox, and relays it on
    /// `udpInputPort`. Sox handles both mono and stereo Gqrx output; `channels`
    /// must match the Gqrx Audio→Stereo setting (1 = mono, 2 = stereo).
    ///
    /// Binds PCMUDPReceiver to `::1` (IPv6 loopback) because Gqrx (Qt) resolves
    /// "localhost" to `::1` and sends datagrams there. AF_INET (127.0.0.1) never
    /// receives those packets; AF_INET6 (::1) does.
    ///
    /// Uses `waitForDyingProcesses: true` so the dying pipeline releases port
    /// 7355 before the new PCMUDPReceiver tries to bind it.
    func startGqrxListening(channels: Int = 2) {
        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()
        taskMode = .customTask
        activeFrequencyID = nil
        statusFunction = "Gqrx"
        stationName = "Gqrx"
        modulation = ""
        frequencyDisplay = ""
        sampleRate = Self.outputSampleRate
        tunerGain = 0
        squelchLevel = 0
        options = ""
        audioOutputFilter = ""
        tunerAGC = false
        directSamplingQBranch = false
        lastError = nil

        guard let receiver = makeUDPReceiverTaskItem(port: gqrxReceivePort, bind: "::1"),
              let resample = makeResampleTaskItem(inputRate: Self.outputSampleRate,
                                                 inputChannels: max(1, channels),
                                                 audioOutputFilter: "vol 1"),
              let sender = makeUDPSenderTaskItem() else { return }
        radioTaskPipelineManager.add(receiver)
        radioTaskPipelineManager.add(resample)
        addTranscriberStageIfEnabled()
        radioTaskPipelineManager.add(sender)
        launchCurrentPipeline(dying: dying, waitForDyingProcesses: true)
    }

    private func makeUDPReceiverTaskItem(port: UInt16, bind: String = "127.0.0.1") -> TaskItem? {
        let path = helperPath("PCMUDPReceiver")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastError = SDRError.notImplemented("PCMUDPReceiver helper missing at \(path)")
            LogStore.shared.log(.error, source: "SDRController", "PCMUDPReceiver helper missing at \(path)")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path,
                                                         functionName: "PCMUDPReceiver")
        item.addArgument("--port"); item.addArgument(Int(port))
        item.addArgument("--bind"); item.addArgument(bind)
        item.addArgument("--exit-with-parent")
        return item
    }

    /// Start a PCMSpeechSynth → sox → PCMUDPSender pipeline that speaks the text
    /// files picked in the "Text to Speech" web UI. The files' text arrives from
    /// the browser (the sandboxed app can't read an arbitrary folder), so this
    /// just orders them — by modification date, or shuffled when `randomOrder` —
    /// concatenates the text into one container-local temp file, and points
    /// PCMSpeechSynth at it. `repeatForever` maps to the helper's `--repeat`
    /// (the whole concatenated sequence loops, with a short gap between passes).
    func startTextToSpeech(files: [SpeechTextFile], randomOrder: Bool, repeatForever: Bool) {
        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()

        let ordered = randomOrder ? files.shuffled() : files.sorted { $0.modified < $1.modified }
        let combined = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !combined.isEmpty else {
            lastError = SDRError.notImplemented("Text to Speech — no text to speak (choose a folder of .txt files first)")
            LogStore.shared.log(.error, source: "SDRController", "Text to Speech: nothing to speak")
            return
        }

        // Stage the combined text in the app's own temp dir (inside the sandbox
        // container, so the PCMSpeechSynth child can read it) rather than passing
        // it as a --text argument, which would risk ARG_MAX for a large folder.
        let textFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntennaHead-TTS-\(UUID().uuidString).txt")
        do {
            try combined.write(to: textFileURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = error
            LogStore.shared.log(.error, source: "SDRController", "Text to Speech: could not stage text file: \(error)")
            return
        }
        cleanUpSpeechSynthTextFile()
        speechSynthTextFileURL = textFileURL

        taskMode = .customTask
        activeFrequencyID = nil
        statusFunction = "Text to Speech" + (repeatForever ? " (repeating)" : "")
        stationName = "Text to Speech"
        modulation = ""
        frequencyDisplay = ""
        sampleRate = Self.outputSampleRate
        tunerGain = 0
        squelchLevel = 0
        options = ""
        audioOutputFilter = ""
        tunerAGC = false
        directSamplingQBranch = false
        lastError = nil

        guard let synth = makeSpeechSynthTaskItem(textFileURL: textFileURL, repeatForever: repeatForever),
              let resample = makeResampleTaskItem(inputRate: Self.speechSynthSampleRate,
                                                  inputChannels: 1,
                                                  audioOutputFilter: "vol 1"),
              let sender = makeUDPSenderTaskItem() else {
            taskMode = .stopped
            return
        }
        radioTaskPipelineManager.add(synth)
        radioTaskPipelineManager.add(resample)
        addTranscriberStageIfEnabled()
        radioTaskPipelineManager.add(sender)
        launchCurrentPipeline(dying: dying)
    }

    private func makeSpeechSynthTaskItem(textFileURL: URL, repeatForever: Bool) -> TaskItem? {
        let path = helperPath("PCMSpeechSynth")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastError = SDRError.notImplemented("PCMSpeechSynth helper missing at \(path)")
            LogStore.shared.log(.error, source: "SDRController", "PCMSpeechSynth helper missing at \(path)")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path, functionName: "PCMSpeechSynth")
        item.addArgument("--input"); item.addArgument("file:\(textFileURL.path)")
        item.addArgument("--rate"); item.addArgument(Self.speechSynthSampleRate)
        if repeatForever {
            item.addArgument("--repeat")
            item.addArgument("--gap"); item.addArgument(2)
        }
        item.addArgument("--exit-with-parent")
        return item
    }

    private func cleanUpSpeechSynthTextFile() {
        if let url = speechSynthTextFileURL {
            try? FileManager.default.removeItem(at: url)
            speechSynthTextFileURL = nil
        }
    }

    // MARK: Announcement pipeline plumbing

    private struct PreparedAnnouncement {
        let stage: TaskItem
        let pending: PendingAnnouncement
    }

    /// Builds the PCMPrefix stage and the matching render request for `text`,
    /// or returns `nil` when announcements are off, there's nothing to say, or
    /// the helper is missing. `holdInput` picks PCMPrefix's `--during-prefix`
    /// mode: `false` (drop) for a live source that must not block, `true`
    /// (hold) for a self-pacing file player that should resume from its start.
    private func prepareAnnouncement(text: String, holdInput: Bool) -> PreparedAnnouncement? {
        cleanUpAnnouncementClip()   // drop any clip staged for a previous tuning
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard announcementEnabled, !trimmed.isEmpty else { return nil }

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntennaHead-announce-\(UUID().uuidString).raw")

        guard let stage = makeAnnouncementPrefixTaskItem(clipURL: clipURL, holdInput: holdInput) else {
            return nil
        }
        announcementClipURL = clipURL
        return PreparedAnnouncement(
            stage: stage,
            pending: PendingAnnouncement(text: trimmed,
                                         voiceIdentifier: validatedAnnouncementVoiceIdentifier(),
                                         clipURL: clipURL))
    }

    /// PCMPrefix stage: plays the announcement clip, then passes the live audio
    /// through. Sits immediately before PCMUDPSender. A missing/empty clip file
    /// makes PCMPrefix a plain passthrough, so a failed render is harmless.
    private func makeAnnouncementPrefixTaskItem(clipURL: URL, holdInput: Bool) -> TaskItem? {
        let path = helperPath("PCMPrefix")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            LogStore.shared.log(.error, source: "SDRController",
                                "PCMPrefix helper missing at \(path) — announcement skipped")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path, functionName: "PCMPrefix")
        item.addArgument("--prefix-file"); item.addArgument(clipURL.path)
        item.addArgument("--prefix-channels"); item.addArgument(1)   // PCMSpeechSynth emits mono
        item.addArgument("--rate"); item.addArgument(Self.outputSampleRate)
        item.addArgument("--channels"); item.addArgument(Self.outputChannels)
        item.addArgument("--during-prefix"); item.addArgument(holdInput ? "hold" : "drop")
        item.addArgument("--exit-with-parent")
        return item
    }

    /// The configured announcement voice, but only if the system still has it —
    /// PCMSpeechSynth aborts on an unknown identifier, so an uninstalled voice
    /// falls back to the system default (nil).
    private func validatedAnnouncementVoiceIdentifier() -> String? {
        guard let id = (try? sqliteController.appSettingsValue(forKey: Self.announcementVoiceKey)) ?? nil,
              !id.isEmpty else { return nil }
        if AVSpeechSynthesisVoice(identifier: id) != nil { return id }
        LogStore.shared.log(.info, source: "SDRController",
                            "announcement: saved voice '\(id)' is unavailable; using the system default")
        return nil
    }

    private func cleanUpAnnouncementClip() {
        if let url = announcementClipURL {
            try? FileManager.default.removeItem(at: url)
            announcementClipURL = nil
        }
    }

    /// Renders `announcement.text` to a raw S16LE mono clip at
    /// `announcementRenderRate` by running PCMSpeechSynth once (not through the
    /// pipeline manager). Best-effort: on any failure the clip file is left
    /// missing/empty and PCMPrefix simply plays nothing.
    private static func renderAnnouncementClip(_ announcement: PendingAnnouncement) async {
        let synthPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PCMSpeechSynth").path
        guard FileManager.default.isExecutableFile(atPath: synthPath) else {
            LogStore.shared.log(.error, source: "SDRController",
                                "announcement: PCMSpeechSynth helper missing at \(synthPath)")
            return
        }

        FileManager.default.createFile(atPath: announcement.clipURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: announcement.clipURL) else {
            LogStore.shared.log(.error, source: "SDRController",
                                "announcement: could not open clip file for writing")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: synthPath)
        var args = ["--text", announcement.text,
                    "--rate", "\(announcementRenderRate)",
                    "--no-pace", "--exit-with-parent"]
        if let voice = announcement.voiceIdentifier, !voice.isEmpty {
            args.append(contentsOf: ["--voice", voice])
        }
        process.arguments = args
        process.standardOutput = outHandle
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            LogStore.shared.log(.error, source: "SDRController",
                                "announcement: could not start PCMSpeechSynth: \(error)")
            try? outHandle.close()
            return
        }

        await withTaskCancellationHandler {
            await waitForProcessExit(process, timeout: 10)
        } onCancel: {
            process.terminate()
        }
        try? outHandle.close()

        if process.isRunning {
            process.terminate()
            LogStore.shared.log(.error, source: "SDRController", "announcement: render timed out")
        } else if process.terminationStatus != 0 {
            LogStore.shared.log(.error, source: "SDRController",
                                "announcement: PCMSpeechSynth exited \(process.terminationStatus)")
        }
    }

    private static func waitForProcessExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func terminateTasks() {
        pipelineStartTask?.cancel()
        pipelineStartTask = nil
        radioTaskPipelineManager.terminate()
        cleanUpSpeechSynthTextFile()
        cleanUpAnnouncementClip()
        // The SRT transcript itself is a user artifact — leave it on disk, just
        // drop the reference so the next pipeline's log line is accurate.
        transcriptFileURL = nil
        resetCaptions()
        taskMode = .stopped
        activeFrequencyID = nil
        statusFunction = "No active tuning"
        signalLevel = 0
        activeDeviceSerial = ""
        activeDeviceIndex = -1
        activeChannelCount = 0
    }

    /// Waits for all processes to exit (polling `isRunning`), then SIGKILLs any
    /// that outlast `timeout`. This is the SDR-controller equivalent of the same
    /// helper in AirPlayReceiverController — ensures ports are free before the
    /// replacement pipeline tries to bind them.
    private static func waitForProcessesToExit(_ processes: [Process], timeout: TimeInterval = 2.5) async {
        var alive = processes.filter { $0.isRunning }
        let deadline = Date().addingTimeInterval(timeout)
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            alive = alive.filter { $0.isRunning }
        }
        for proc in alive { kill(proc.processIdentifier, SIGKILL) }
        if !alive.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Defers `radioTaskPipelineManager.start()` to an async Task that first
    /// waits for `dying` processes to exit (avoiding port races on retune or
    /// source↔radio transitions). Cancels any pending launch from a previous
    /// call so rapid successive requests don't queue up stale pipelines.
    ///
    /// `waitForDyingProcesses`: skip when the pipeline being *started* is a
    /// PCMUDPReceiver → PCMUDPSender bridge (ControlBooth listening) —
    /// regardless of what `dying` was (a radio tuning, a device capture, another
    /// bridge, …), since the bridge never contends for an exclusive OS resource
    /// (RTL-SDR USB, a Core Audio device) the way rtl_fm/AudioInputCapture do,
    /// and PCMUDPReceiver binds with SO_REUSEADDR. This trades the ~2.5s
    /// worst-case wait for switch latency.
    ///
    /// KNOWN RISK (noted 2026-07-26, unverified in practice): skipping the wait
    /// means the new PCMUDPReceiver can bind its port a few milliseconds before
    /// the old one has actually exited (SIGTERM delivery + process teardown
    /// isn't instantaneous). SO_REUSEADDR should make this harmless on macOS,
    /// but if ControlBooth listening ever intermittently drops the
    /// first moment of audio after switching sources, or logs a stray UDP bind
    /// failure right after a Listen click, check here first.
    private func launchCurrentPipeline(dying: [Process],
                                       waitForDyingProcesses: Bool = true,
                                       announcement: PendingAnnouncement? = nil) {
        pipelineStartTask?.cancel()
        pipelineStartTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if waitForDyingProcesses, !dying.isEmpty {
                await Self.waitForProcessesToExit(dying)
                guard !Task.isCancelled else { return }
            }
            if let announcement {
                // Render the "Now playing …" clip the PCMPrefix stage will read.
                await Self.renderAnnouncementClip(announcement)
                guard !Task.isCancelled else { return }
            }
            do {
                try self.radioTaskPipelineManager.start()
                self.lastError = nil
            } catch {
                self.lastError = error
                self.taskMode = .stopped
                self.activeFrequencyID = nil
                LogStore.shared.log(.error, source: "SDRController", "pipeline start failed: \(error)")
            }
        }
    }

    // MARK: Tuning resolution

    private struct Tuning {
        var modulation: String
        var squelchLevel: Int
        var squelchDelay: Int
        var firSize: Int
        var tunerGain: Double
        var sampleRate: Int
        var usbDevice: String
        var biasT: Bool
        var oversampling: Int
        var atanMath: String
        var directQBranch: Bool
        var tunerAGC: Bool
        var stereoFlag: Bool
        var options: String
        var audioOutputFilter: String
        /// Already-formatted rtl_fm frequency arguments, e.g. ["-f", "89100000"].
        var frequencyArgs: [String]
        var stationName: String
        var statusFunction: String
        /// What the optional spoken announcement says before playback starts.
        var announcementText: String
    }

    private func makeTuning(forFrequency f: Frequency) -> Tuning {
        Tuning(
            modulation: f.modulation,
            squelchLevel: Int(f.squelchLevel),
            squelchDelay: 0,   // not stored per-frequency in LocalRadio
            firSize: f.firSize,
            tunerGain: f.tunerGain,
            sampleRate: f.sampleRate,
            usbDevice: f.usbDeviceString.isEmpty ? "0" : f.usbDeviceString,
            biasT: f.biasTFlag == 1,
            oversampling: f.oversampling,
            atanMath: f.atanMath,
            directQBranch: f.samplingMode == 2,
            tunerAGC: f.tunerAgc == 1,
            stereoFlag: f.stereoFlag,
            options: f.options,
            audioOutputFilter: f.audioOutputFilter,
            frequencyArgs: frequencyArguments(for: f),
            stationName: f.stationName,
            statusFunction: "Tuned to \(f.stationName)",
            announcementText: Self.announcementText(forFrequency: f)
        )
    }

    private func makeTuning(forCategory c: Category, frequencies: [Frequency]) -> Tuning {
        var freqArgs: [String] = []
        for f in frequencies {
            freqArgs.append(contentsOf: frequencyArguments(for: f))
        }
        return Tuning(
            modulation: c.scanModulation,
            squelchLevel: Int(c.scanSquelchLevel),
            squelchDelay: Int(c.scanSquelchDelay),
            firSize: c.scanFirSize,
            tunerGain: c.scanTunerGain,
            sampleRate: c.scanSampleRate,
            usbDevice: c.scanUsbDeviceString.isEmpty ? "0" : c.scanUsbDeviceString,
            biasT: c.scanBiasTFlag == 1,
            oversampling: c.scanOversampling,
            atanMath: c.scanAtanMath,
            directQBranch: c.scanSamplingMode == 2,
            tunerAGC: c.scanTunerAgc == 1,
            stereoFlag: false,   // category scan has no stereo setting; stays mono
            options: c.scanOptions,
            audioOutputFilter: c.scanAudioOutputFilter,
            frequencyArgs: freqArgs,
            stationName: c.categoryName,
            statusFunction: "Scanning category: \(c.categoryName)",
            announcementText: "Scanning \(c.categoryName.trimmingCharacters(in: .whitespacesAndNewlines))."
        )
    }

    // MARK: Announcement text

    /// The line the spoken announcement reads for a saved or ad-hoc frequency:
    /// `"Now playing <station name>."`, plus `" <freq> <band>."` for a fixed
    /// (non-scan) tuning when the station name doesn't already carry them.
    /// Modulation maps to a spoken band: fm/wfm/nfm → "F M", am → "A M",
    /// usb/lsb → "upper/lower sideband", everything else → omit the band.
    static func announcementText(forFrequency f: Frequency) -> String {
        let rawName = f.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An ad-hoc web-Tuner tuning has no real name: SDRController fills
        // stationName with a formatted readout ("89.1000 MHz") for the UI.
        // Don't speak that back verbatim — the zero-padded, "MHz"-suffixed
        // form reads badly. Treat it as unnamed and let the phrase below say
        // the frequency cleanly ("89.1 F M").
        let name = isFrequencyOnlyName(rawName) ? "" : rawName

        let number = spokenFrequencyNumber(f)
        let band = spokenBand(f.modulation)
        let phrase = band.isEmpty ? "\(number) megahertz" : "\(number) \(band)"

        guard f.frequencyMode == 0 else {
            return "Now playing \(name.isEmpty ? "this station" : name)."
        }
        if name.isEmpty {
            return "Now playing \(phrase)."
        }

        var text = "Now playing \(name)."
        // Skip the tail if the name already spells the frequency or band out.
        let nameKey = name.lowercased().filter { !$0.isWhitespace }
        let saysNumber = nameKey.contains(number.filter { !$0.isWhitespace })
        let saysBand = !band.isEmpty && nameKey.contains(band.lowercased().filter { !$0.isWhitespace })
        if !(saysNumber && (band.isEmpty || saysBand)) {
            text += " \(phrase)."
        }
        return text
    }

    /// The line the spoken announcement reads when listening to a Core Audio
    /// input device: `"Now playing <device>."`, or a generic fallback when the
    /// device name is blank.
    static func announcementText(forDevice deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Now playing audio input." : "Now playing \(name)."
    }

    /// The line the spoken announcement reads when playing a recording:
    /// `"Now playing <name>."` with the file extension dropped so it isn't read
    /// aloud, or a generic fallback when the name is blank.
    static func announcementText(forRecording fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Now playing recording." : "Now playing \(base)."
    }

    /// The line the spoken announcement reads when a ControlBooth feed is the
    /// source: `"Now playing <name>."`, or a generic fallback when blank.
    static func announcementText(forControlBooth name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Now playing Control Booth." : "Now playing \(trimmed)."
    }

    /// True when `name` is just a frequency readout — digits with a decimal
    /// point and/or an "MHz"/"kHz" suffix — i.e. the placeholder
    /// `startTasksForFrequency` stores for an ad-hoc tuning, not a name the
    /// listener chose. A bare integer ("1010") is left alone: it could be a
    /// station's on-air name.
    private static func isFrequencyOnlyName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let hadUnit = lower.contains("mhz") || lower.contains("khz")
        let digits = lower
            .replacingOccurrences(of: "mhz", with: "")
            .replacingOccurrences(of: "khz", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return hadUnit || digits.contains(".")
    }

    /// "89.1", "162.4", "1010" — trailing zeros trimmed, spoken as a number.
    private static func spokenFrequencyNumber(_ f: Frequency) -> String {
        let mhz = Double(f.frequency) / 1_000_000.0
        var s = String(format: "%.3f", mhz)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func spokenBand(_ modulation: String) -> String {
        switch modulation.lowercased() {
        case "fm", "wfm", "nfm": return "F M"
        case "am": return "A M"
        case "usb": return "upper sideband"
        case "lsb": return "lower sideband"
        default: return ""
        }
    }

    /// rtl_fm frequency argument(s) for a record: a single frequency, or a
    /// `start:end:interval` scan range when `frequencyMode == 1`.
    private func frequencyArguments(for f: Frequency) -> [String] {
        if f.frequencyMode == 1 {
            return ["-f", "\(f.frequency):\(f.frequencyScanEnd):\(f.frequencyScanInterval)"]
        }
        return ["-f", "\(f.frequency)"]
    }

    // MARK: Pipeline assembly

    private func startPipeline(with tuning: Tuning) {
        // Capture dying processes before terminate() clears the references.
        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()

        // FM-stereo stations decode the multiplex into L/R via stereodemux,
        // which then feeds sox as 2-channel; everything else stays mono into sox
        // (which upmixes to dual-mono on output).
        // The stereo L-R DSB-SC subcarrier spans 23–53 kHz, so stereodemux
        // requires a sample rate above 106 kHz (Nyquist for 53 kHz). Below that
        // the subcarrier is aliased away and stereo decoding produces noise.
        let isStereo = (tuning.modulation == "fm" || tuning.modulation == "wfm")
                    && tuning.stereoFlag
                    && tuning.sampleRate > 106_000

        // Resolve + publish status now: the old rtl_fm has just been terminated
        // above and the new one hasn't launched yet, so this is the one moment
        // the RTL-SDR dongle's EEPROM serial can actually be read.
        publishStatus(tuning, isStereo: isStereo)
        // wfm = wide/broadcast FM: apply de-emphasis after sox at 48 kHz so the
        // filter runs on clean audio-rate samples, not the raw FM multiplex.
        let isBroadcastFM = tuning.modulation == "wfm"

        let source = makeRTLSDRSourceTaskItem(tuning)
        let stereoDemux = isStereo ? makeStereoDemuxTaskItem(tuning) : nil
        let resample = makeResampleTaskItem(inputRate: tuning.sampleRate,
                                            inputChannels: isStereo ? 2 : 1,
                                            audioOutputFilter: tuning.audioOutputFilter)
        let deemphasis = isBroadcastFM ? makeDeemphasisTaskItem() : nil
        let udpSender = makeUDPSenderTaskItem()

        guard let source, let resample, let udpSender,
              !(isStereo && stereoDemux == nil),
              !(isBroadcastFM && deemphasis == nil) else {
            taskMode = .stopped
            activeFrequencyID = nil
            return  // lastError already set by the failing builder
        }

        // Optional spoken "Now playing …" clip, played by a PCMPrefix stage
        // just before the UDP sender. `drop` mode: the live rtl_fm source keeps
        // running and its first ~clip-length of audio is discarded rather than
        // stalling the tuner.
        let announcement = prepareAnnouncement(text: tuning.announcementText, holdInput: false)

        radioTaskPipelineManager.add(source)
        if let stereoDemux { radioTaskPipelineManager.add(stereoDemux) }
        radioTaskPipelineManager.add(resample)
        if let deemphasis { radioTaskPipelineManager.add(deemphasis) }
        if let announcement { radioTaskPipelineManager.add(announcement.stage) }
        addTranscriberStageIfEnabled()
        radioTaskPipelineManager.add(udpSender)

        launchCurrentPipeline(dying: dying, announcement: announcement?.pending)
    }

    /// AudioInputCapture source stage: captures the named Core Audio input and
    /// emits 48 kHz / 2-channel S16LE on stdout.
    private func makeAudioCaptureTaskItem(deviceName: String) -> TaskItem? {
        let path = helperPath("AudioInputCapture")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastError = SDRError.notImplemented("AudioInputCapture helper missing at \(path)")
            LogStore.shared.log(.error, source: "SDRController", "AudioInputCapture helper missing at \(path)")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path,
                                                         functionName: "AudioInputCapture")
        item.addArgument("--device-name"); item.addArgument(deviceName)
        item.addArgument("--rate"); item.addArgument(Self.outputSampleRate)
        item.addArgument("--channels"); item.addArgument(Self.outputChannels)
        item.addArgument("--exit-with-parent")
        return item
    }

    private func publishDeviceStatus(deviceName: String, filter: String) {
        statusFunction = "Listening to \(deviceName)"
        stationName = deviceName
        modulation = ""
        frequencyDisplay = ""
        sampleRate = Self.outputSampleRate
        tunerGain = 0
        squelchLevel = 0
        options = ""
        audioOutputFilter = filter
        tunerAGC = false
        directSamplingQBranch = false
    }

    private func makeRTLSDRSourceTaskItem(_ tuning: Tuning) -> TaskItem? {
        let item = radioTaskPipelineManager.makeTaskItem(
            pathToExecutable: helperPath("rtl_fm_localradio"),
            functionName: "rtl_fm_localradio")

        item.addArgument("-M"); item.addArgument(tuning.modulation)
        item.addArgument("-l"); item.addArgument(tuning.squelchLevel)
        item.addArgument("-t"); item.addArgument(tuning.squelchDelay)
        item.addArgument("-F"); item.addArgument(tuning.firSize)
        item.addArgument("-g"); item.addArgument("\(tuning.tunerGain)")
        item.addArgument("-s"); item.addArgument(tuning.sampleRate)
        item.addArgument("-d"); item.addArgument(tuning.usbDevice)

        if tuning.biasT { item.addArgument("-T") }
        if tuning.oversampling > 0 {
            item.addArgument("-o"); item.addArgument(tuning.oversampling)
        }
        item.addArgument("-A"); item.addArgument(tuning.atanMath)
        item.addArgument("-p"); item.addArgument("0")
        // rtl_fm streams "Frequency:/RMS Power:" status to this local UDP port;
        // RTLSDRStatusListener parses it into `signalLevel`.
        item.addArgument("-c"); item.addArgument(Int(statusUDPPort))
        item.addArgument("-E"); item.addArgument("pad")

        if tuning.directQBranch {
            item.addArgument("-E"); item.addArgument("direct")
        }
        if tuning.tunerAGC {
            item.addArgument("-E"); item.addArgument("agc")
        }
        for token in tuning.options.split(separator: " ") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                item.addArgument("-E"); item.addArgument(trimmed)
            }
        }
        for arg in tuning.frequencyArgs {
            item.addArgument(arg)
        }
        return item
    }

    /// stereodemux stage: decodes rtl_fm's wideband FM multiplex (mono S16LE at
    /// the tuner rate) into interleaved S16LE stereo at the same rate, which the
    /// sox stage then resamples. Ported from LocalRadio's StereoDemux step.
    private func makeStereoDemuxTaskItem(_ tuning: Tuning) -> TaskItem? {
        let path = helperPath("stereodemux")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastError = SDRError.notImplemented("stereodemux helper missing at \(path)")
            LogStore.shared.log(.error, source: "SDRController", "stereodemux helper missing at \(path)")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path,
                                                         functionName: "stereodemux")
        item.addArgument("-r"); item.addArgument(tuning.sampleRate)
        return item
    }

    /// FMDeemphasis stage: first-order IIR de-emphasis (75 µs, U.S. standard)
    /// applied at 48 kHz after sox resampling, one stage before PCMUDPSender.
    /// Used for wfm (broadcast FM) only.
    private func makeDeemphasisTaskItem() -> TaskItem? {
        let path = helperPath("FMDeemphasis")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastError = SDRError.notImplemented("FMDeemphasis helper missing at \(path)")
            LogStore.shared.log(.error, source: "SDRController", "FMDeemphasis helper missing at \(path)")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path,
                                                         functionName: "FMDeemphasis")
        item.addArgument("--rate"); item.addArgument(Self.outputSampleRate)
        item.addArgument("--channels"); item.addArgument(Self.outputChannels)
        item.addArgument("--tau"); item.addArgument("75.0")
        return item
    }

    /// sox stage: resample the upstream audio to S16LE 2-channel 48000 Hz (the
    /// LiveAudioServer UDP-input contract) and apply the station's audio filter.
    /// `inputChannels` is 2 when fed by stereodemux, else 1 (mono is upmixed to
    /// dual-mono on output). Replaces LocalRadio's AudioMonitor2 resampling step.
    private func makeResampleTaskItem(inputRate: Int, inputChannels: Int, audioOutputFilter: String) -> TaskItem? {
        let item: TaskItem
        do {
            item = try radioTaskPipelineManager.makeSoxTaskItem()
        } catch {
            lastError = error
            LogStore.shared.log(.error, source: "SDRController", "\(error)")
            return nil
        }

        item.addArgument("-V2")     // show failures and warnings
        item.addArgument("-q")      // no terminal audio meter

        // Keep sox's processing block small in *time*, independent of input rate.
        // sox's default buffer (8192 bytes) is ~0.4 s at a 10 kHz mono input, so
        // it reads/emits in ~0.4 s bursts; LiveAudioServer's idle detector then
        // injects silence between bursts, producing choppy narrowband audio.
        // (Wideband is unaffected — the same byte buffer is only ~25 ms there.)
        // Size the buffer for ~50 ms at the input rate so audio flows steadily.
        let blockBytes = max(1024, inputRate * inputChannels * 2 / 20)
        item.addArgument("--buffer"); item.addArgument(blockBytes)

        // Input: raw S16LE at rtl_fm's/stereodemux's output (tuner) sample rate.
        item.addArgument("-r"); item.addArgument(inputRate)
        item.addArgument("-e"); item.addArgument("signed-integer")
        item.addArgument("-b"); item.addArgument(16)
        item.addArgument("-c"); item.addArgument(inputChannels)
        item.addArgument("-t"); item.addArgument("raw")
        item.addArgument("-")       // stdin

        // Output: raw S16LE, 2-channel (mono input is duplicated to both).
        item.addArgument("-e"); item.addArgument("signed-integer")
        item.addArgument("-b"); item.addArgument(16)
        item.addArgument("-c"); item.addArgument(Self.outputChannels)
        item.addArgument("-t"); item.addArgument("raw")
        item.addArgument("-")       // stdout

        // Resample to the output rate, then apply the station's filter tokens.
        item.addArgument("rate"); item.addArgument(Self.outputSampleRate)
        let trimmedFilter = audioOutputFilter.trimmingCharacters(in: .whitespaces)
        for token in trimmedFilter.split(separator: " ") {
            let t = token.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { item.addArgument(t) }
        }
        return item
    }

    private func makeUDPSenderTaskItem() -> TaskItem? {
        let item = radioTaskPipelineManager.makeTaskItem(
            pathToExecutable: helperPath("PCMUDPSender"),
            functionName: "PCMUDPSender")
        item.addArgument("--port"); item.addArgument(Int(udpInputPort))
        // Tear the whole pipeline down (via SIGPIPE upstream) if the app dies,
        // even on a crash where app-side cleanup can't run.
        item.addArgument("--exit-with-parent")
        return item
    }

    /// Adds the optional `PCMTranscriber` speech-to-text tap immediately before
    /// the terminal `PCMUDPSender`. Every pipeline builder calls this right
    /// before adding its UDP sender; it's a no-op unless transcription is
    /// enabled in Configuration and the helper binary is present. Because the
    /// stage is a byte-for-byte passthrough, a missing helper or a recognizer
    /// failure never affects the audio the listener hears.
    ///
    /// The tap runs on the normalized 48 kHz / 2 ch stream (every pipeline has
    /// resampled or bridged to the LiveAudioServer contract by this point), so
    /// its `--rate`/`--channels` are the fixed output constants regardless of
    /// the source. Caption JSON always goes to `transcriptionUDPPort`; an SRT
    /// transcript is also written to the shared Recordings folder when the
    /// "save transcript" setting is on.
    private func addTranscriberStageIfEnabled() {
        transcriptFileURL = nil
        // A new pipeline means a new (or no) tap — start its transcript fresh.
        resetCaptions()
        guard transcriptionEnabled else { return }

        let path = helperPath("PCMTranscriber")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            LogStore.shared.log(.error, source: "SDRController",
                                "PCMTranscriber helper missing at \(path) — captions disabled for this tuning")
            return
        }

        let locale = transcriptionLocale
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path, functionName: "PCMTranscriber")
        item.addArgument("--rate"); item.addArgument(Self.outputSampleRate)
        item.addArgument("--channels"); item.addArgument(Self.outputChannels)
        item.addArgument("--locale"); item.addArgument(locale)
        item.addArgument("--udp-port"); item.addArgument(Int(transcriptionUDPPort))
        // Volatile hypotheses too, so a caption consumer gets low-latency text;
        // the SRT file still only ever receives finalized segments.
        item.addArgument("--partials")
        if transcriptionSavesFile, let url = makeTranscriptFileURL() {
            transcriptFileURL = url
            item.addArgument("--transcript-file"); item.addArgument(url.path)
        }
        item.addArgument("--exit-with-parent")
        radioTaskPipelineManager.add(item)

        LogStore.shared.log(.info, source: "SDRController",
                            "speech-to-text tap on (\(locale)) — captions → udp:\(transcriptionUDPPort)"
                            + (transcriptFileURL.map { ", transcript → \($0.lastPathComponent)" } ?? ""))
    }

    /// Destination for the optional SRT transcript: `<station> <timestamp>.srt`
    /// in the shared App Group Recordings folder (same folder tab recordings and
    /// ControlBooth-triggered captures use). `nil` if that folder can't be
    /// resolved, in which case the tap still emits the UDP caption feed.
    private func makeTranscriptFileURL() -> URL? {
        guard let folder = SharedRecordingFolder.url else {
            LogStore.shared.log(.error, source: "SDRController",
                                "transcription: shared Recordings folder unavailable — no SRT file written")
            return nil
        }
        let stamp = Self.transcriptTimestampFormatter.string(from: Date())
        let rawName = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = rawName.isEmpty ? "transcript" : rawName
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return folder.appendingPathComponent("\(safe) \(stamp).srt")
    }

    private func helperPath(_ name: String) -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(name)")
            .path
    }

    // MARK: Orphaned-helper sweep

    /// Best-effort cleanup of helper processes left over from a previous session
    /// (still under this bundle's `Contents/Helpers/`, reparented to launchd /
    /// PPID 1). Restricting to PPID 1 targets only true orphans — never this
    /// app's live children nor another instance's.
    ///
    /// NOTE: under the App Sandbox a process generally cannot signal a
    /// non-descendant, so this `kill()` typically fails with EPERM (and process
    /// enumeration may be restricted too). It is kept as a harmless fallback for
    /// unsandboxed runs (e.g. tests); the *primary* defense against orphans is
    /// each helper's parent-death watchdog — PCMUDPSender and LiveAudioServer's
    /// `--exit-with-parent`, and rtl_fm_localradio's built-in getppid watchdog —
    /// which lets every helper reap itself when the app dies.
    private static func sweepOrphanedHelpers() {
        let helpersDir = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path
        let prefix = helpersDir.hasSuffix("/") ? helpersDir : helpersDir + "/"

        for proc in runningProcesses() where proc.ppid == 1 {
            guard let path = executablePath(forPID: proc.pid), path.hasPrefix(prefix) else { continue }
            if kill(proc.pid, SIGKILL) == 0 {
                LogStore.shared.log(.info, source: "SDRController", "reaped orphaned helper PID=\(proc.pid) \(path)")
            } else {
                LogStore.shared.log(.error, source: "SDRController",
                    "failed to reap orphaned helper PID=\(proc.pid) \(path) — errno=\(errno)")
            }
        }
    }

    private struct ProcessEntry {
        let pid: pid_t
        let ppid: pid_t
    }

    /// Snapshot of all processes via `sysctl(KERN_PROC_ALL)`, reduced to pid/ppid.
    private static func runningProcesses() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }

        // The table can shrink between the sizing and fetching calls; trust the
        // byte count returned by the second call.
        let count = size / stride
        return procs.prefix(count).map {
            ProcessEntry(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid)
        }
    }

    /// Resolves a process's executable path, or nil if it can't be inspected
    /// (e.g. it exited, or belongs to another user).
    private static func executablePath(forPID pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro isn't imported into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private func publishStatus(_ tuning: Tuning, isStereo: Bool) {
        statusFunction = tuning.statusFunction
        stationName = tuning.stationName
        modulation = tuning.modulation
        sampleRate = tuning.sampleRate
        tunerGain = tuning.tunerGain
        squelchLevel = tuning.squelchLevel
        options = tuning.options
        audioOutputFilter = tuning.audioOutputFilter
        tunerAGC = tuning.tunerAGC
        directSamplingQBranch = tuning.directQBranch
        frequencyDisplay = tuning.frequencyArgs
            .filter { $0 != "-f" }
            .joined(separator: ", ")

        let resolved = resolveActiveDevice(tuning.usbDevice)
        activeDeviceSerial = resolved.serial
        activeDeviceIndex = resolved.index
        activeChannelCount = isStereo ? 2 : 1
    }

    /// Resolves a "USB Device" field value — a bare index ("0") or an RTL-SDR
    /// EEPROM serial (optionally shorter than the canonical 8 digits, as typed
    /// into the web UI) — against the connected dongles. Returns the matched
    /// serial (possibly "") and USB index (-1 when the device isn't connected).
    /// Mirrors librtlsdr's `verbose_device_search`: a single bare digit is a
    /// device index, anything else is treated as a serial. Blocks briefly on
    /// libusb enumeration; only ever called at tune time (see `startPipeline`).
    private func resolveActiveDevice(_ value: String) -> (serial: String, index: Int) {
        let devices = RTLSDRDeviceList.enumerate()
        for device in devices where !device.serial.isEmpty {
            deviceSerialByIndex[device.index] = device.serial
        }

        func serial(forIndex index: UInt32) -> String {
            if let s = devices.first(where: { $0.index == index })?.serial, !s.isEmpty { return s }
            return deviceSerialByIndex[index] ?? ""
        }

        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Bare single digit → USB index.
        if trimmed.count == 1, let index = Int(trimmed), index >= 0 {
            let u = UInt32(index)
            let connected = devices.contains { $0.index == u } || deviceSerialByIndex[u] != nil
            return connected ? (serial(forIndex: u), index) : ("", -1)
        }

        // Otherwise a serial. Zero-pad an all-digit value to the 8-digit
        // rtl_eeprom format and match either form.
        let padded = (!trimmed.isEmpty && trimmed.count < 8 && trimmed.allSatisfy(\.isNumber))
            ? String(repeating: "0", count: 8 - trimmed.count) + trimmed
            : trimmed
        if let device = devices.first(where: { $0.serial == padded || $0.serial == trimmed }) {
            let s = device.serial.isEmpty ? serial(forIndex: device.index) : device.serial
            return (s, Int(device.index))
        }
        // Fall back: the value also parses as a multi-digit device index.
        if let index = Int(trimmed), index >= 0,
           devices.contains(where: { $0.index == UInt32(index) }) {
            return (serial(forIndex: UInt32(index)), index)
        }
        return ("", -1)
    }
}
