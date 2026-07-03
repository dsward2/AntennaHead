import Foundation

/// One FM station row from the FCC FM Query service. Field indices follow the
/// pipe-delimited `fmq` response format (see `FCCSearch.search`).
struct FCCStationRecord: Identifiable, Hashable {
    let id = UUID()
    var callSign: String
    /// e.g. "88.3 MHz" (as returned, whitespace collapsed).
    var frequencyText: String
    var city: String
    var state: String
    var erp: String
    var licensee: String
    var distanceKm: Int
    var distanceMiles: Int
    var directionDegrees: Int

    /// Frequency in Hz parsed from `frequencyText` ("88.3 MHz" → 88_300_000).
    var frequencyHz: Int {
        let scanner = Scanner(string: frequencyText)
        guard let mhz = scanner.scanDouble() else { return 0 }
        return Int(mhz * 1_000_000)
    }

    /// 16-point compass name for `directionDegrees` (port of LocalRadio's
    /// direction column, which coarsens to 8 names).
    var compassDirection: String {
        let names = ["N", "NE", "NE", "E", "E", "SE", "SE", "S",
                     "S", "SW", "SW", "W", "W", "NW", "NW", "N"]
        let point = Int(Double(directionDegrees) / 22.5) % 16
        return names[point >= 0 ? point : point + 16]
    }
}

/// FM-station search against the FCC's FM Query database, ported from
/// LocalRadio's FCCSearchController. A bundled `zip_lat_long.txt` maps 5-digit
/// ZIP codes to coordinates; the query asks for all licensed FM stations
/// within a radius of that point.
enum FCCSearch {
    enum SearchError: LocalizedError {
        case unknownZIPCode
        case badResponse

        var errorDescription: String? {
            switch self {
            case .unknownZIPCode: return "The ZIP code was not found."
            case .badResponse: return "The FCC database returned an unreadable response."
            }
        }
    }

    /// ZIP → (latitude, longitude), loaded once from the bundled CSV
    /// (`ZIP,LAT,LNG` header plus one line per ZIP code).
    private static let zipCoordinates: [Int: (lat: Double, lon: Double)] = {
        guard let url = Bundle.main.url(forResource: "zip_lat_long", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var table: [Int: (lat: Double, lon: Double)] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",")
            guard fields.count == 3,
                  let zip = Int(fields[0].trimmingCharacters(in: .whitespaces)), zip > 0,
                  let lat = Double(fields[1].trimmingCharacters(in: .whitespaces)),
                  let lon = Double(fields[2].trimmingCharacters(in: .whitespaces)) else { continue }
            table[zip] = (lat, lon)
        }
        return table
    }()

    static func coordinate(forZIPCode zip: Int) -> (lat: Double, lon: Double)? {
        zipCoordinates[zip]
    }

    /// Fetches licensed FM stations within `radiusKm` of the coordinate,
    /// sorted by distance. The `fmq` service takes degrees/minutes/seconds
    /// plus hemisphere letters and returns pipe-delimited text (list=4).
    static func search(latitude: Double, longitude: Double, radiusKm: Int) async throws -> [FCCStationRecord] {
        func dms(_ degrees: Double) -> (d: Int, m: Int, s: Int) {
            var seconds = Int(abs(degrees) * 3600)
            let d = seconds / 3600
            seconds %= 3600
            return (d, seconds / 60, seconds % 60)
        }
        let lat = dms(latitude), lon = dms(longitude)
        let ns = latitude < 0 ? "S" : "N"
        let ew = longitude < 0 ? "W" : "E"

        var c = URLComponents(string: "https://transition.fcc.gov/fcc-bin/fmq")!
        c.queryItems = [
            .init(name: "call", value: ""), .init(name: "arn", value: ""),
            .init(name: "state", value: ""), .init(name: "city", value: ""),
            .init(name: "freq", value: "0.0"), .init(name: "fre2", value: "107.9"),
            .init(name: "serv", value: ""), .init(name: "vac", value: ""),
            .init(name: "facid", value: ""), .init(name: "asrn", value: ""),
            .init(name: "class", value: ""), .init(name: "list", value: "4"),
            .init(name: "dist", value: "\(radiusKm)"),
            .init(name: "dlat2", value: "\(lat.d)"), .init(name: "mlat2", value: "\(lat.m)"),
            .init(name: "slat2", value: "\(lat.s)"), .init(name: "NS", value: ns),
            .init(name: "dlon2", value: "\(lon.d)"), .init(name: "mlon2", value: "\(lon.m)"),
            .init(name: "slon2", value: "\(lon.s)"), .init(name: "EW", value: ew),
            .init(name: "size", value: "9")
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SearchError.badResponse
        }
        return parse(text)
    }

    /// Parses the pipe-delimited `fmq` response: one station per line,
    /// ≥ 39 fields, keeping only "FM" service records (as LocalRadio did).
    private static func parse(_ text: String) -> [FCCStationRecord] {
        var records: [FCCStationRecord] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: "|").map { field in
                field.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "    ", with: " ")
                    .replacingOccurrences(of: "   ", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .replacingOccurrences(of: ". ", with: " ")
            }
            guard fields.count >= 39, fields[3] == "FM" else { continue }
            records.append(FCCStationRecord(
                callSign: fields[1],
                frequencyText: fields[2],
                city: fields[10],
                state: fields[11],
                erp: fields[15],
                licensee: fields[27],
                distanceKm: Int(Double(fields[28].replacingOccurrences(of: " km", with: "")) ?? 0),
                distanceMiles: Int(Double(fields[29].replacingOccurrences(of: " mi", with: "")) ?? 0),
                directionDegrees: Int(Double(fields[30].replacingOccurrences(of: " deg", with: "")) ?? 0)
            ))
        }
        return records.sorted { $0.distanceKm < $1.distanceKm }
    }
}
