import Foundation

/// JSON exchange format for sharing tuning data (Favorites, Categories and their
/// links) between AntennaHead users.
///
/// Records are identified by *content*, not by database row IDs (which mean
/// nothing on another machine): a category by its name, a favorite by its
/// tuning, and a favorite's category membership by category name.
///
/// Deliberately **not** part of the format: the USB device string (it names
/// one specific dongle), custom tasks (they define processes to run) and app
/// settings. The bias-tee flag is exported for information only and always
/// imports as off.
struct ShareFile: Codable, Equatable {
    static let formatID = "antennahead-share"
    static let currentVersion = 1

    var format: String
    var version: Int
    var exportedAt: String
    var appVersion: String?
    /// Free text a sender can use to say what the file is and where it applies,
    /// e.g. region "Little Rock, AR".
    var title: String?
    var region: String?
    var notes: String?
    var categories: [SharedCategory]
    var favorites: [SharedFavorite]

    enum CodingKeys: String, CodingKey {
        case format, version
        case exportedAt = "exported_at"
        case appVersion = "app_version"
        case title, region, notes, categories, favorites
    }
}

struct SharedCategory: Codable, Equatable {
    var name: String
    var scanningEnabled: Int
    var scanTunerGain: Double
    var scanTunerAgc: Int
    var scanSamplingMode: Int
    var scanSampleRate: Int
    var scanOversampling: Int
    var scanModulation: String
    var scanSquelchLevel: Double
    var scanSquelchDelay: Double
    var scanOptions: String
    var scanFirSize: Int
    var scanAtanMath: String
    var scanAudioOutputFilter: String
    var scanBiasTFlag: Int

    enum CodingKeys: String, CodingKey {
        case name
        case scanningEnabled = "category_scanning_enabled"
        case scanTunerGain = "scan_tuner_gain"
        case scanTunerAgc = "scan_tuner_agc"
        case scanSamplingMode = "scan_sampling_mode"
        case scanSampleRate = "scan_sample_rate"
        case scanOversampling = "scan_oversampling"
        case scanModulation = "scan_modulation"
        case scanSquelchLevel = "scan_squelch_level"
        case scanSquelchDelay = "scan_squelch_delay"
        case scanOptions = "scan_options"
        case scanFirSize = "scan_fir_size"
        case scanAtanMath = "scan_atan_math"
        case scanAudioOutputFilter = "scan_audio_output_filter"
        case scanBiasTFlag = "scan_bias_t_flag"
    }
}

struct SharedFavorite: Codable, Equatable {
    var stationName: String
    var frequencyMode: Int
    var frequency: Int
    var frequencyScanEnd: Int
    var frequencyScanInterval: Int
    var frequencyScanSquelchDelay: Double
    var tunerGain: Double
    var tunerAgc: Int
    var samplingMode: Int
    var sampleRate: Int
    var oversampling: Int
    var modulation: String
    var squelchLevel: Double
    var options: String
    var firSize: Int
    var atanMath: String
    var audioOutputFilter: String
    var stereoFlag: Bool
    var biasTFlag: Int
    /// Names of the (exported) categories this favorite belongs to.
    var categories: [String]

    enum CodingKeys: String, CodingKey {
        case stationName = "station_name"
        case frequencyMode = "frequency_mode"
        case frequency
        case frequencyScanEnd = "frequency_scan_end"
        case frequencyScanInterval = "frequency_scan_interval"
        case frequencyScanSquelchDelay = "frequency_scan_squelch_delay"
        case tunerGain = "tuner_gain"
        case tunerAgc = "tuner_agc"
        case samplingMode = "sampling_mode"
        case sampleRate = "sample_rate"
        case oversampling, modulation
        case squelchLevel = "squelch_level"
        case options
        case firSize = "fir_size"
        case atanMath = "atan_math"
        case audioOutputFilter = "audio_output_filter"
        case stereoFlag = "stereo_flag"
        case biasTFlag = "bias_t_flag"
        case categories
    }
}

// MARK: - Record mapping

extension SharedCategory {
    init(_ c: Category) {
        self.init(name: c.categoryName, scanningEnabled: c.categoryScanningEnabled,
                  scanTunerGain: c.scanTunerGain, scanTunerAgc: c.scanTunerAgc,
                  scanSamplingMode: c.scanSamplingMode, scanSampleRate: c.scanSampleRate,
                  scanOversampling: c.scanOversampling, scanModulation: c.scanModulation,
                  scanSquelchLevel: c.scanSquelchLevel, scanSquelchDelay: c.scanSquelchDelay,
                  scanOptions: c.scanOptions, scanFirSize: c.scanFirSize,
                  scanAtanMath: c.scanAtanMath, scanAudioOutputFilter: c.scanAudioOutputFilter,
                  scanBiasTFlag: c.scanBiasTFlag)
    }

    /// A new local record. The USB device string is left blank and bias-T off.
    func makeRecord(named name: String) -> Category {
        Category(id: nil, categoryName: name, categoryScanningEnabled: scanningEnabled,
                 scanTunerGain: scanTunerGain, scanTunerAgc: scanTunerAgc,
                 scanSamplingMode: scanSamplingMode, scanSampleRate: scanSampleRate,
                 scanOversampling: scanOversampling, scanModulation: scanModulation,
                 scanSquelchLevel: scanSquelchLevel, scanSquelchDelay: scanSquelchDelay,
                 scanOptions: scanOptions, scanFirSize: scanFirSize, scanAtanMath: scanAtanMath,
                 scanAudioOutputFilter: scanAudioOutputFilter, scanBiasTFlag: 0,
                 scanUsbDeviceString: "")
    }

    /// Copies the shared tuning settings onto an existing record, keeping its
    /// identity, USB device string and bias-T setting.
    func apply(to c: inout Category) {
        c.categoryScanningEnabled = scanningEnabled
        c.scanTunerGain = scanTunerGain; c.scanTunerAgc = scanTunerAgc
        c.scanSamplingMode = scanSamplingMode; c.scanSampleRate = scanSampleRate
        c.scanOversampling = scanOversampling; c.scanModulation = scanModulation
        c.scanSquelchLevel = scanSquelchLevel; c.scanSquelchDelay = scanSquelchDelay
        c.scanOptions = scanOptions; c.scanFirSize = scanFirSize
        c.scanAtanMath = scanAtanMath; c.scanAudioOutputFilter = scanAudioOutputFilter
    }

    /// Names of the settings that differ (bias-T and USB device excluded — they
    /// are never imported).
    func differences(from o: SharedCategory) -> [String] {
        var d: [String] = []
        if scanningEnabled != o.scanningEnabled { d.append("scanning enabled") }
        if !scanTunerGain.isClose(to: o.scanTunerGain) { d.append("tuner gain") }
        if scanTunerAgc != o.scanTunerAgc { d.append("AGC") }
        if scanSamplingMode != o.scanSamplingMode { d.append("sampling mode") }
        if scanSampleRate != o.scanSampleRate { d.append("sample rate") }
        if scanOversampling != o.scanOversampling { d.append("oversampling") }
        if scanModulation != o.scanModulation { d.append("modulation") }
        if !scanSquelchLevel.isClose(to: o.scanSquelchLevel) { d.append("squelch level") }
        if !scanSquelchDelay.isClose(to: o.scanSquelchDelay) { d.append("squelch delay") }
        if scanOptions != o.scanOptions { d.append("options") }
        if scanFirSize != o.scanFirSize { d.append("FIR size") }
        if scanAtanMath != o.scanAtanMath { d.append("atan math") }
        if scanAudioOutputFilter != o.scanAudioOutputFilter { d.append("audio filter") }
        return d
    }
}

extension SharedFavorite {
    init(_ f: Frequency, categoryNames: [String]) {
        self.init(stationName: f.stationName, frequencyMode: f.frequencyMode, frequency: f.frequency,
                  frequencyScanEnd: f.frequencyScanEnd, frequencyScanInterval: f.frequencyScanInterval,
                  frequencyScanSquelchDelay: f.frequencyScanSquelchDelay,
                  tunerGain: f.tunerGain, tunerAgc: f.tunerAgc, samplingMode: f.samplingMode,
                  sampleRate: f.sampleRate, oversampling: f.oversampling, modulation: f.modulation,
                  squelchLevel: f.squelchLevel, options: f.options, firSize: f.firSize,
                  atanMath: f.atanMath, audioOutputFilter: f.audioOutputFilter,
                  stereoFlag: f.stereoFlag, biasTFlag: f.biasTFlag, categories: categoryNames)
    }

    /// A new local record. The USB device string is left blank and bias-T off.
    func makeRecord(named name: String) -> Frequency {
        Frequency(id: nil, stationName: name, frequencyMode: frequencyMode, frequency: frequency,
                  frequencyScanEnd: frequencyScanEnd, frequencyScanInterval: frequencyScanInterval,
                  frequencyScanSquelchDelay: frequencyScanSquelchDelay,
                  tunerGain: tunerGain, tunerAgc: tunerAgc, samplingMode: samplingMode,
                  sampleRate: sampleRate, oversampling: oversampling, modulation: modulation,
                  squelchLevel: squelchLevel, options: options, firSize: firSize, atanMath: atanMath,
                  audioOutputFilter: audioOutputFilter, stereoFlag: stereoFlag,
                  usbDeviceString: "", biasTFlag: 0)
    }

    /// Overwrites the shared settings of an existing record, keeping its
    /// identity, USB device string and bias-T setting.
    func apply(to f: inout Frequency) {
        f.stationName = stationName; f.frequencyMode = frequencyMode; f.frequency = frequency
        f.frequencyScanEnd = frequencyScanEnd; f.frequencyScanInterval = frequencyScanInterval
        f.frequencyScanSquelchDelay = frequencyScanSquelchDelay
        f.tunerGain = tunerGain; f.tunerAgc = tunerAgc; f.samplingMode = samplingMode
        f.sampleRate = sampleRate; f.oversampling = oversampling; f.modulation = modulation
        f.squelchLevel = squelchLevel; f.options = options; f.firSize = firSize
        f.atanMath = atanMath; f.audioOutputFilter = audioOutputFilter; f.stereoFlag = stereoFlag
    }

    /// Two favorites are "the same tuning" when these match.
    var tuningKey: String { "\(frequencyMode)|\(frequency)|\(frequencyScanEnd)|\(modulation)" }

    func differences(from o: SharedFavorite) -> [String] {
        var d: [String] = []
        if stationName != o.stationName { d.append("name") }
        if frequencyScanInterval != o.frequencyScanInterval { d.append("scan interval") }
        if !frequencyScanSquelchDelay.isClose(to: o.frequencyScanSquelchDelay) { d.append("scan squelch delay") }
        if !tunerGain.isClose(to: o.tunerGain) { d.append("tuner gain") }
        if tunerAgc != o.tunerAgc { d.append("AGC") }
        if samplingMode != o.samplingMode { d.append("sampling mode") }
        if sampleRate != o.sampleRate { d.append("sample rate") }
        if oversampling != o.oversampling { d.append("oversampling") }
        if !squelchLevel.isClose(to: o.squelchLevel) { d.append("squelch level") }
        if options != o.options { d.append("options") }
        if firSize != o.firSize { d.append("FIR size") }
        if atanMath != o.atanMath { d.append("atan math") }
        if audioOutputFilter != o.audioOutputFilter { d.append("audio filter") }
        if stereoFlag != o.stereoFlag { d.append("stereo") }
        return d
    }
}

extension Double {
    func isClose(to other: Double) -> Bool { abs(self - other) < 1e-9 }
}
