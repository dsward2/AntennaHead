import Foundation

/// Checks and normalizes data read from a shared file. Files come from other
/// people, and several of these strings end up on helper-process command lines
/// (rtl_fm `-E` tokens, sox effect chains), so everything is range-checked or
/// restricted to a conservative character set before it can reach the database.
enum ShareValidator {
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxFavorites = 5000
    static let maxCategories = 500
    static let maxNameLength = 120

    enum FileError: LocalizedError {
        case tooLarge, notJSON, wrongFormat, newerVersion(Int), tooManyItems

        var errorDescription: String? {
            switch self {
            case .tooLarge: "The file is too large to be an AntennaHead share file."
            case .notJSON: "The file isn't a valid AntennaHead share file (it couldn't be read as JSON)."
            case .wrongFormat: "This JSON file isn't an AntennaHead share file."
            case .newerVersion(let v): "This file was made by a newer version of AntennaHead (format version \(v)). Update AntennaHead to import it."
            case .tooManyItems: "The file contains more items than AntennaHead will import at once."
            }
        }
    }

    static func decode(_ data: Data) throws -> ShareFile {
        guard data.count <= maxFileBytes else { throw FileError.tooLarge }
        let file: ShareFile
        do { file = try JSONDecoder().decode(ShareFile.self, from: data) }
        catch {
            // Valid JSON but the wrong shape is a different problem from not-JSON.
            if (try? JSONSerialization.jsonObject(with: data)) != nil { throw FileError.wrongFormat }
            throw FileError.notJSON
        }
        guard file.format == ShareFile.formatID else { throw FileError.wrongFormat }
        guard file.version <= ShareFile.currentVersion else { throw FileError.newerVersion(file.version) }
        guard file.favorites.count <= maxFavorites, file.categories.count <= maxCategories
        else { throw FileError.tooManyItems }
        return file
    }

    struct Rejection: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    // MARK: Individual records

    /// Returns a cleaned copy, or a reason the record can't be imported.
    static func validated(_ f: SharedFavorite) -> Result<SharedFavorite, Rejection> {
        var f = f
        guard let name = cleanName(f.stationName) else { return .failure(.init("has no usable name")) }
        f.stationName = name
        guard (0...1).contains(f.frequencyMode) else { return .failure(.init("unknown frequency mode \(f.frequencyMode)")) }
        guard (1...2_200_000_000).contains(f.frequency) else { return .failure(.init("frequency \(f.frequency) Hz is out of range")) }
        guard (0...2_200_000_000).contains(f.frequencyScanEnd) else { return .failure(.init("scan end frequency is out of range")) }
        guard (0...100_000_000).contains(f.frequencyScanInterval) else { return .failure(.init("scan interval is out of range")) }
        guard f.frequencyScanSquelchDelay.isFinite, (0...600).contains(f.frequencyScanSquelchDelay) else { return .failure(.init("scan squelch delay is out of range")) }
        if f.frequencyMode == 1, f.frequencyScanEnd < f.frequency { return .failure(.init("scan range ends before it starts")) }
        guard Frequency.modulationOptions.contains(f.modulation) else { return .failure(.init("unknown modulation \"\(f.modulation)\"")) }
        if let problem = commonProblem(gain: f.tunerGain, agc: f.tunerAgc, sampling: f.samplingMode,
                                       rate: f.sampleRate, oversampling: f.oversampling,
                                       squelch: f.squelchLevel, fir: f.firSize) {
            return .failure(.init(problem))
        }
        guard let atan = cleanAtan(f.atanMath) else { return .failure(.init("unknown atan math \"\(f.atanMath)\"")) }
        guard let options = cleanOptions(f.options) else { return .failure(.init("has unsupported characters in its options")) }
        guard let filter = cleanFilter(f.audioOutputFilter) else { return .failure(.init("has unsupported characters in its audio filter")) }
        f.atanMath = atan; f.options = options; f.audioOutputFilter = filter
        f.categories = f.categories.compactMap(cleanName)
        return .success(f)
    }

    static func validated(_ c: SharedCategory) -> Result<SharedCategory, Rejection> {
        var c = c
        guard let name = cleanName(c.name) else { return .failure(.init("has no usable name")) }
        c.name = name
        guard Frequency.modulationOptions.contains(c.scanModulation) else { return .failure(.init("unknown modulation \"\(c.scanModulation)\"")) }
        guard (0...1).contains(c.scanningEnabled) else { return .failure(.init("invalid scanning flag")) }
        guard c.scanSquelchDelay.isFinite, (0...600).contains(c.scanSquelchDelay) else { return .failure(.init("squelch delay is out of range")) }
        if let problem = commonProblem(gain: c.scanTunerGain, agc: c.scanTunerAgc, sampling: c.scanSamplingMode,
                                       rate: c.scanSampleRate, oversampling: c.scanOversampling,
                                       squelch: c.scanSquelchLevel, fir: c.scanFirSize) {
            return .failure(.init(problem))
        }
        guard let atan = cleanAtan(c.scanAtanMath) else { return .failure(.init("unknown atan math \"\(c.scanAtanMath)\"")) }
        guard let options = cleanOptions(c.scanOptions) else { return .failure(.init("has unsupported characters in its options")) }
        guard let filter = cleanFilter(c.scanAudioOutputFilter) else { return .failure(.init("has unsupported characters in its audio filter")) }
        c.scanAtanMath = atan; c.scanOptions = options; c.scanAudioOutputFilter = filter
        return .success(c)
    }

    // MARK: Field rules

    private static func commonProblem(gain: Double, agc: Int, sampling: Int, rate: Int,
                                      oversampling: Int, squelch: Double, fir: Int) -> String? {
        if !gain.isFinite || !(0...60).contains(gain) { return "tuner gain is out of range" }
        if !(0...1).contains(agc) { return "invalid AGC flag" }
        if !(0...2).contains(sampling) { return "unknown sampling mode \(sampling)" }
        if !(1_000...3_200_000).contains(rate) { return "sample rate \(rate) is out of range" }
        if !(0...32).contains(oversampling) { return "oversampling is out of range" }
        if !squelch.isFinite || !(0...1_000).contains(squelch) { return "squelch level is out of range" }
        if !(-1...9).contains(fir) { return "FIR size is out of range" }
        return nil
    }

    /// Station and category names: printable, no control characters, trimmed.
    static func cleanName(_ s: String) -> String? {
        let scalars = s.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\u{2028}" && $0 != "\u{2029}"
        }
        let t = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return String(t.prefix(maxNameLength))
    }

    private static let atanModes: Set<String> = ["std", "fast", "lut", "ale"]
    private static func cleanAtan(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return atanModes.contains(t) ? t : nil
    }

    /// Each token becomes the value of an `rtl_fm -E` flag: short, plain words only.
    private static func cleanOptions(_ s: String) -> String? {
        let tokens = s.split(separator: " ").map(String.init)
        guard tokens.count <= 10 else { return nil }
        for t in tokens where t.count > 24
            || !t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return nil
        }
        return tokens.joined(separator: " ")
    }

    /// A sox effect chain such as "compand .1,.3 9:-15,0,-9 -6 -90 .1 vol 8":
    /// letters, digits and a few punctuation marks. No quotes, slashes or paths.
    private static func cleanFilter(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count <= 200 else { return nil }
        let allowed = Set(" .,:_%+=-")
        guard t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || allowed.contains($0)) }) else { return nil }
        return t
    }
}
