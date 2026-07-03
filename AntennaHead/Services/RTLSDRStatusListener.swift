import Foundation
import Network

/// Listens on a local UDP port for the status feed emitted by
/// `rtl_fm_localradio -c <port>`. The helper connects to `127.0.0.1:<port>` and
/// sends an ASCII message roughly every 100 ms:
///
///     Frequency: <hz>\nRMS Power: <rms>\n
///
/// This parses the `RMS Power:` value (the demodulator's RMS signal level) and
/// hands it to `onRMSPower`. Internal mutable state is confined to `queue`
/// (or set once from the owner before `start()`), so accesses don't race.
final class RTLSDRStatusListener: @unchecked Sendable {
    /// Invoked on a background queue each time a new RMS power value arrives.
    var onRMSPower: (@Sendable (Int) -> Void)?

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.dsward.AntennaHead.RTLSDRStatusListener")
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
                // rtl_fm reconnects (new source port) on each retune; keep only
                // the newest flow.
                self.currentConnection?.cancel()
                self.currentConnection = connection
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("RTLSDRStatusListener: failed to listen on \(port) - \(error)")
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
            if let data, let text = String(data: data, encoding: .ascii) {
                self.parse(text)
            }
            // Keep reading the same flow until it errors out.
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func parse(_ text: String) {
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "RMS Power:") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let rms = Int(value) {
                onRMSPower?(rms)
            }
        }
    }
}
