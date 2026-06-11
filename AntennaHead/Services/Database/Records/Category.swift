import Foundation
import GRDB

struct Category: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var categoryName: String
    var categoryScanningEnabled: Int
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
    var scanUsbDeviceString: String

    static let databaseTableName = "category"

    enum CodingKeys: String, CodingKey {
        case id
        case categoryName = "category_name"
        case categoryScanningEnabled = "category_scanning_enabled"
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
        case scanUsbDeviceString = "scan_usb_device_string"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let frequencies = hasMany(Frequency.self, through: hasMany(FreqCat.self), using: FreqCat.frequency)

    static func prototype(name: String = "Unnamed Category") -> Category {
        Category(
            id: nil,
            categoryName: name,
            categoryScanningEnabled: 0,
            scanTunerGain: 49.5,
            scanTunerAgc: 0,
            scanSamplingMode: 0,
            scanSampleRate: 10_000,
            scanOversampling: 4,
            scanModulation: "fm",
            scanSquelchLevel: 25,
            scanSquelchDelay: 10,
            scanOptions: "",
            scanFirSize: 9,
            scanAtanMath: "std",
            scanAudioOutputFilter: "vol 1",
            scanBiasTFlag: 0,
            scanUsbDeviceString: ""
        )
    }
}
