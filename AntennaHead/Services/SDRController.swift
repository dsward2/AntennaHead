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
    }

    enum SDRError: Error, CustomStringConvertible {
        case frequencyNotFound(Int64)
        case categoryNotFound(Int64)
        case categoryHasNoFrequencies(Int64)
        case customTaskNotFound(Int64)
        case customTaskHasNoStages(Int64)
        case notImplemented(String)

        var description: String {
            switch self {
            case .frequencyNotFound(let id): return "No frequency record found for id \(id)."
            case .categoryNotFound(let id): return "No category record found for id \(id)."
            case .categoryHasNoFrequencies(let id): return "Category \(id) has no frequencies to scan."
            case .customTaskNotFound(let id): return "No custom task record found for id \(id)."
            case .customTaskHasNoStages(let id): return "Custom task \(id) has no tasks defined."
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
    /// UDP port PCMUDPReceiver listens on for PCM datagrams from the AirPlay
    /// Receiver's own always-running capture pipeline (see
    /// `AirPlayReceiverProcessManager`). Switching to another source just tears
    /// down this relay bridge — the capture pipeline keeps running and sending
    /// here regardless, so AirPlay listening can resume later without a fresh
    /// AirPlay session.
    private(set) var airPlayReceivePort: UInt16 = 6022
    private var statusListener: RTLSDRStatusListener?

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
    private(set) var lastError: Error?

    init(sqliteController: SQLiteController? = nil, udpInputPort: UInt16, statusUDPPort: UInt16 = 6021) {
        self.sqliteController = sqliteController ?? .shared
        self.udpInputPort = udpInputPort
        self.statusUDPPort = statusUDPPort
        radioTaskPipelineManager.onLog = { source, message in
            LogStore.shared.log(.info, source: source, message)
        }
        startStatusListener()
    }

    /// Applies the configured UDP ports (Configuration sheet). The audio port
    /// takes effect when the next pipeline is built; a changed status port
    /// recreates the rtl_fm status listener immediately.
    func updatePorts(udpInput: UInt16, statusUDP: UInt16, controlBoothReceive: UInt16 = 6019, airPlayReceive: UInt16 = 6022) {
        udpInputPort = udpInput
        controlBoothReceivePort = controlBoothReceive
        airPlayReceivePort = airPlayReceive
        guard statusUDP != statusUDPPort else { return }
        statusUDPPort = statusUDP
        statusListener?.stop()
        startStatusListener()
    }

    private func startStatusListener() {
        statusListener = RTLSDRStatusListener(port: statusUDPPort)
        statusListener?.onRMSPower = { [weak self] rms in
            Task { @MainActor in self?.signalLevel = rms }
        }
        statusListener?.start()
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
    /// `modulation == "fm"` and `stereo`).
    func startTasksForFrequency(frequencyHz: Int, sampleRate: Int, tunerGain: Double,
                                stereo: Bool, modulation: String) {
        var f = Frequency.prototype()
        f.frequency = frequencyHz
        f.sampleRate = sampleRate
        f.tunerGain = tunerGain
        f.stereoFlag = stereo
        f.modulation = modulation.isEmpty ? "fm" : modulation
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

        radioTaskPipelineManager.add(capture)
        radioTaskPipelineManager.add(resample)
        radioTaskPipelineManager.add(udpSender)

        launchCurrentPipeline(dying: dying)
    }

    /// Listen to a custom task: a user-defined pipe of external executables
    /// (`task_json`) whose final stage emits raw S16LE at the record's
    /// `sample_rate`/`channels`, which sox then normalizes to 48 kHz / 2 ch.
    ///
    /// Note: under the App Sandbox, launching binaries at arbitrary external
    /// paths (e.g. `/Applications/rtl-sdr/...`) may be denied; such a task will
    /// fail to start and surface via `lastError`.
    func startTasksForCustomTask(id: Int64) throws {
        guard let task = try sqliteController.customTask(forID: id) else {
            throw SDRError.customTaskNotFound(id)
        }
        let stages = Self.parseCustomTaskStages(task.taskJson)
        guard !stages.isEmpty else {
            throw SDRError.customTaskHasNoStages(id)
        }

        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()

        taskMode = .customTask
        activeFrequencyID = nil
        publishCustomTaskStatus(name: task.taskName)

        var items: [TaskItem] = stages.map { stage in
            let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: Self.resolveToolPath(stage.path),
                                                             functionName: URL(fileURLWithPath: stage.path).lastPathComponent)
            for arg in stage.arguments { item.addArgument(arg) }
            return item
        }
        // sox normalizes the task's output rate/channels to the 48 kHz / 2 ch
        // LiveAudioServer contract (time-based buffer avoids low-rate glitches).
        guard let resample = makeResampleTaskItem(inputRate: task.sampleRate,
                                                  inputChannels: max(1, task.channels),
                                                  audioOutputFilter: "vol 1"),
              let udpSender = makeUDPSenderTaskItem() else {
            taskMode = .stopped
            return
        }
        items.append(resample)
        items.append(udpSender)
        items.forEach { radioTaskPipelineManager.add($0) }

        // waitForPort5000: custom tasks may include shairport-sync (port 5000),
        // which conflicts if the AirPlay receiver hasn't fully released it yet.
        launchCurrentPipeline(dying: dying, waitForPort5000: true)
    }

    private struct CustomTaskStage {
        let path: String
        let arguments: [String]
    }

    /// Resolves a custom-task stage's executable path. Delegates to the
    /// canonical implementation in `AntennaHeadHTTPServer` so the logic
    /// stays in one place for both launch-time resolution and CLI export.
    static func resolveToolPath(_ path: String) -> String {
        AntennaHeadHTTPServer.resolveToolPath(path)
    }

    /// Parses `task_json` (`{"tasks":[{"path":..,"arguments":[..]}]}`) into stages.
    private static func parseCustomTaskStages(_ json: String) -> [CustomTaskStage] {
        struct Payload: Decodable {
            struct Task: Decodable { let path: String; let arguments: [String]? }
            let tasks: [Task]
        }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.tasks
            .filter { !$0.path.isEmpty }
            .map { CustomTaskStage(path: $0.path, arguments: $0.arguments ?? []) }
    }

    private func publishCustomTaskStatus(name: String) {
        statusFunction = "Using Custom Task '\(name)'"
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
        radioTaskPipelineManager.add(receiver)
        radioTaskPipelineManager.add(sender)
        launchCurrentPipeline(dying: dying, waitForDyingProcesses: false)
    }

    /// Start a PCMUDPReceiver → PCMUDPSender bridge pipeline that picks up PCM
    /// from the AirPlay Receiver's own always-running capture pipeline (on
    /// `airPlayReceivePort`) and relays it to LiveAudioServer on `udpInputPort`.
    /// Mirrors `startControlBoothListening`: switching to a *different* source
    /// later just tears this bridge down via `terminateTasks()`/`launchCurrentPipeline`
    /// — the AirPlay capture pipeline (shairport-sync/sox/PCMUDPSender) isn't
    /// touched, so it keeps receiving silently and can be reconnected later by
    /// calling this again.
    func startAirPlayListening(deviceName: String) {
        let dying = radioTaskPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        Self.sweepOrphanedHelpers()
        radioTaskPipelineManager.terminate()
        taskMode = .customTask
        activeFrequencyID = nil
        statusFunction = "AirPlay Receiver: \(deviceName)"
        stationName = deviceName
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

        guard let receiver = makeUDPReceiverTaskItem(port: airPlayReceivePort),
              let sender = makeUDPSenderTaskItem() else { return }
        radioTaskPipelineManager.add(receiver)
        radioTaskPipelineManager.add(sender)
        launchCurrentPipeline(dying: dying, waitForDyingProcesses: false)
    }

    private func makeUDPReceiverTaskItem(port: UInt16) -> TaskItem? {
        let path = helperPath("PCMUDPReceiver")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastError = SDRError.notImplemented("PCMUDPReceiver helper missing at \(path)")
            LogStore.shared.log(.error, source: "SDRController", "PCMUDPReceiver helper missing at \(path)")
            return nil
        }
        let item = radioTaskPipelineManager.makeTaskItem(pathToExecutable: path,
                                                         functionName: "PCMUDPReceiver")
        item.addArgument("--port"); item.addArgument(Int(port))
        item.addArgument("--exit-with-parent")
        return item
    }

    func terminateTasks() {
        pipelineStartTask?.cancel()
        pipelineStartTask = nil
        radioTaskPipelineManager.terminate()
        taskMode = .stopped
        activeFrequencyID = nil
        statusFunction = "No active tuning"
        signalLevel = 0
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
    /// AirPlay↔radio transitions). Cancels any pending launch from a previous
    /// call so rapid successive requests don't queue up stale pipelines.
    ///
    /// `waitForPort5000`: pass `true` for custom tasks that may include
    /// shairport-sync, so the task waits for TCP port 5000 to be free after
    /// stopping the AirPlay receiver.
    ///
    /// `waitForDyingProcesses`: skip when the pipeline being *started* is a
    /// PCMUDPReceiver → PCMUDPSender bridge (ControlBooth/AirPlay listening) —
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
    /// but if AirPlay/ControlBooth listening ever intermittently drops the
    /// first moment of audio after switching sources, or logs a stray UDP bind
    /// failure right after a Listen click, check here first.
    private func launchCurrentPipeline(dying: [Process], waitForPort5000: Bool = false,
                                       waitForDyingProcesses: Bool = true) {
        pipelineStartTask?.cancel()
        pipelineStartTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if waitForDyingProcesses, !dying.isEmpty {
                await Self.waitForProcessesToExit(dying)
                guard !Task.isCancelled else { return }
            }
            if waitForPort5000 {
                await HelperProcessPreflight.waitForTCPPortFree(5000, timeout: 2.0)
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
            statusFunction: "Tuned to \(f.stationName)"
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
            statusFunction: "Scanning category: \(c.categoryName)"
        )
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

        publishStatus(tuning)

        // FM-stereo stations decode the multiplex into L/R via stereodemux,
        // which then feeds sox as 2-channel; everything else stays mono into sox
        // (which upmixes to dual-mono on output).
        // The stereo L-R DSB-SC subcarrier spans 23–53 kHz, so stereodemux
        // requires a sample rate above 106 kHz (Nyquist for 53 kHz). Below that
        // the subcarrier is aliased away and stereo decoding produces noise.
        let isStereo = (tuning.modulation == "fm" || tuning.modulation == "wfm")
                    && tuning.stereoFlag
                    && tuning.sampleRate > 106_000
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

        radioTaskPipelineManager.add(source)
        if let stereoDemux { radioTaskPipelineManager.add(stereoDemux) }
        radioTaskPipelineManager.add(resample)
        if let deemphasis { radioTaskPipelineManager.add(deemphasis) }
        radioTaskPipelineManager.add(udpSender)

        launchCurrentPipeline(dying: dying)
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

    private func publishStatus(_ tuning: Tuning) {
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
    }
}
