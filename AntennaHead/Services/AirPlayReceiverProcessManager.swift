import Foundation
import Observation
import AirPlayReceiver

/// Manages the AirPlay 1 (RAOP) receiver, mirroring `LiveAudioServerProcessManager`'s
/// shape: a thin `@Observable` wrapper around the shared `AirPlayReceiverController`
/// from the AirPlayReceiver package.
///
/// Unlike LiveAudioServer, the AirPlay receiver shares LiveAudioServer's single
/// UDP input port with `SDRController`'s radio pipeline — only one source can
/// feed that port at a time, so starting one must stop the other. See
/// `sdrController` below.
@MainActor
@Observable
final class AirPlayReceiverProcessManager {
    static let bonjourName = "AntennaHead"

    /// Set by ContentView after both controllers exist, so starting the AirPlay
    /// receiver can stop any active radio pipeline first (and vice versa, via
    /// SDRController's own reference back to this manager).
    weak var sdrController: SDRController?

    private let controller = AirPlayReceiverController(
        configuration: .init(deviceName: AirPlayReceiverProcessManager.bonjourName, udpPort: 0))

    var isRunning: Bool { controller.isRunning }
    var lastError: Error? { controller.lastError }

    func start(deviceName: String, udpInputPort: UInt16) {
        sdrController?.terminateTasks()
        controller.updateConfiguration(.init(deviceName: deviceName, udpPort: udpInputPort))
        controller.start()
    }

    func stop() {
        controller.stop()
    }
}
