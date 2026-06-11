import Foundation
import GRDB

struct Frequency: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var stationName: String
    var frequencyMode: Int
    var frequency: Int
    var frequencyScanEnd: Int
    var frequencyScanInterval: Int
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
    var usbDeviceString: String
    var biasTFlag: Int

    static let databaseTableName = "frequency"

    enum CodingKeys: String, CodingKey {
        case id
        case stationName = "station_name"
        case frequencyMode = "frequency_mode"
        case frequency
        case frequencyScanEnd = "frequency_scan_end"
        case frequencyScanInterval = "frequency_scan_interval"
        case tunerGain = "tuner_gain"
        case tunerAgc = "tuner_agc"
        case samplingMode = "sampling_mode"
        case sampleRate = "sample_rate"
        case oversampling
        case modulation
        case squelchLevel = "squelch_level"
        case options
        case firSize = "fir_size"
        case atanMath = "atan_math"
        case audioOutputFilter = "audio_output_filter"
        case stereoFlag = "stereo_flag"
        case usbDeviceString = "usb_device_string"
        case biasTFlag = "bias_t_flag"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let categories = hasMany(Category.self, through: hasMany(FreqCat.self), using: FreqCat.category)

    var formattedFrequency: String {
        let mhz = Double(frequency) / 1_000_000.0
        return String(format: "%.3f MHz", mhz)
    }

    static let modulationOptions: [String] = [
        "fm", "nfm", "wfm", "am", "usb", "lsb", "raw"
    ]

    static func prototype() -> Frequency {
        Frequency(
            id: nil,
            stationName: "Name missing",
            frequencyMode: 0,
            frequency: 89_100_000,
            frequencyScanEnd: 0,
            frequencyScanInterval: 0,
            tunerGain: 49.5,
            tunerAgc: 0,
            samplingMode: 0,
            sampleRate: 170_000,
            oversampling: 4,
            modulation: "fm",
            squelchLevel: 0,
            options: "",
            firSize: 9,
            atanMath: "std",
            audioOutputFilter: "vol 1",
            stereoFlag: false,
            usbDeviceString: "",
            biasTFlag: 0
        )
    }
}
