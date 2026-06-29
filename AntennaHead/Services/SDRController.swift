import Foundation
import Observation

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
        case notImplemented(String)

        var description: String {
            switch self {
            case .frequencyNotFound(let id): return "No frequency record found for id \(id)."
            case .categoryNotFound(let id): return "No category record found for id \(id)."
            case .categoryHasNoFrequencies(let id): return "Category \(id) has no frequencies to scan."
            case .notImplemented(let what): return "\(what) is not yet implemented."
            }
        }
    }

    // Output format of the pipeline's terminal stage; must match LiveAudioServer's
    // UDP input configuration (see LiveAudioServerProcessManager).
    private static let outputSampleRate = 48_000
    private static let outputChannels = 1

    private let sqliteController: SQLiteController
    /// UDP port the terminal PCMUDPSender stage targets (LiveAudioServer's input).
    private let udpInputPort: UInt16

    let radioTaskPipelineManager = TaskPipelineManager()

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
    private(set) var lastError: Error?

    init(sqliteController: SQLiteController? = nil, udpInputPort: UInt16) {
        self.sqliteController = sqliteController ?? .shared
        self.udpInputPort = udpInputPort
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

    /// Deferred — requires a Core Audio source stage (LocalRadio's AudioMonitor2).
    func startTasksForDevice(deviceName: String, deviceAudioOutputFilter: String) throws {
        throw SDRError.notImplemented("Core Audio device input")
    }

    /// Deferred — requires custom-task JSON parsing and arbitrary source stages.
    func startTasksForCustomTask(id: Int64) throws {
        throw SDRError.notImplemented("Custom task input")
    }

    func terminateTasks() {
        radioTaskPipelineManager.terminate()
        taskMode = .stopped
        activeFrequencyID = nil
        statusFunction = "No active tuning"
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
        if radioTaskPipelineManager.status == .running {
            radioTaskPipelineManager.terminate()
        }

        publishStatus(tuning)

        let source = makeRTLSDRSourceTaskItem(tuning)
        let resample = makeResampleTaskItem(inputRate: tuning.sampleRate,
                                            audioOutputFilter: tuning.audioOutputFilter)
        let udpSender = makeUDPSenderTaskItem()

        guard let source, let resample, let udpSender else {
            taskMode = .stopped
            activeFrequencyID = nil
            return  // lastError already set by the failing builder
        }

        radioTaskPipelineManager.add(source)
        radioTaskPipelineManager.add(resample)
        radioTaskPipelineManager.add(udpSender)

        do {
            try radioTaskPipelineManager.start()
            lastError = nil
        } catch {
            lastError = error
            print("SDRController: failed to start pipeline - \(error)")
            taskMode = .stopped
            activeFrequencyID = nil
        }
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
        // Note: rtl_fm's `-c <StatusPort>` (signal-level UDP) is deferred until a
        // status listener exists.
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

    /// sox stage: resample rtl_fm's mono output to S16LE mono 48000 Hz (the
    /// LiveAudioServer UDP-input contract) and apply the station's audio filter.
    /// Replaces LocalRadio's AudioMonitor2 resampling step.
    private func makeResampleTaskItem(inputRate: Int, audioOutputFilter: String) -> TaskItem? {
        let item: TaskItem
        do {
            item = try radioTaskPipelineManager.makeSoxTaskItem()
        } catch {
            lastError = error
            print("SDRController: \(error)")
            return nil
        }

        item.addArgument("-V2")     // show failures and warnings
        item.addArgument("-q")      // no terminal audio meter

        // Input: raw mono S16LE at rtl_fm's output (tuner) sample rate.
        item.addArgument("-r"); item.addArgument(inputRate)
        item.addArgument("-e"); item.addArgument("signed-integer")
        item.addArgument("-b"); item.addArgument(16)
        item.addArgument("-c"); item.addArgument(Self.outputChannels)
        item.addArgument("-t"); item.addArgument("raw")
        item.addArgument("-")       // stdin

        // Output: raw mono S16LE.
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
