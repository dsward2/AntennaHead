import Foundation
import Network
import SharedLogging

/// One recognized caption line from the `PCMTranscriber` helper (see
/// `PipelineHelpers/Sources/PCMTranscriber/main.swift`).
struct CaptionEvent: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// A volatile hypothesis that may still change; replaces the last one.
        case partial
        /// A finalized segment; appended to the running transcript.
        case final
    }
    let kind: Kind
    let text: String
    /// Audio time range of the segment, in seconds, when the recognizer
    /// reported one (`--transcript-file` SRT timing uses the same values).
    let start: Double?
    let end: Double?
}

/// Listens on a local UDP port for the newline-delimited JSON `PCMTranscriber`
/// emits — one object per datagram:
///
///     {"type":"partial"|"final","text":"…","start":<sec>,"end":<sec>}
///
/// Each complete line is parsed and handed to `onCaption` on a background
/// queue. Same single-newest-flow model as `RTLSDRStatusListener`: the tap is
/// a fresh child process (new UDP source port) every time the pipeline is
/// rebuilt, so only the most recent connection is kept. Internal mutable state
/// is confined to `queue` (or set once from the owner before `start()`).
final class TranscriptionCaptionListener: @unchecked Sendable {
    /// Invoked on a background queue for each parsed caption line.
    var onCaption: (@Sendable (CaptionEvent) -> Void)?

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.dsward.AntennaHead.TranscriptionCaptionListener")
    private var listener: NWListener?
    private var currentConnection: NWConnection?

    init?(port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        self.port = p
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                // The tap reconnects with a new source port on each retune;
                // keep only the newest flow.
                self.currentConnection?.cancel()
                self.currentConnection = connection
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            let message = "failed to listen on \(port) - \(error)"
            Task { @MainActor in
                LogStore.shared.log(.error, source: "TranscriptionCaptionListener", message)
            }
        }
    }

    func stop() {
        currentConnection?.cancel()
        currentConnection = nil
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // A datagram is one JSON object plus a trailing newline, but
                // split defensively in case several are ever coalesced.
                for slice in data.split(separator: 0x0A) where !slice.isEmpty {
                    self.parseLine(Data(slice))
                }
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func parseLine(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let typeString = object["type"] as? String,
            let kind = CaptionEvent.Kind(rawValue: typeString),
            let text = object["text"] as? String
        else { return }
        onCaption?(CaptionEvent(kind: kind,
                                text: text,
                                start: object["start"] as? Double,
                                end: object["end"] as? Double))
    }
}
