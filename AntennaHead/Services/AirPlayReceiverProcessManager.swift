import Foundation
import Observation
import AirPlayReceiver
import SharedLogging

/// Manages the AirPlay 1 (RAOP) receiver, mirroring `LiveAudioServerProcessManager`'s
/// shape: a thin `@Observable` wrapper around the shared `AirPlayReceiverController`
/// from the AirPlayReceiver package.
///
/// This capture pipeline (shairport-sync -> sox -> PCMUDPSender) always sends
/// to its own dedicated port (`PortSettings.airPlayUDP`), independent of
/// whatever `SDRController` is currently listening to — it never touches
/// LiveAudioServer's UDP input directly. `SDRController.startAirPlayListening`
/// is what bridges this port to LiveAudioServer when the user picks AirPlay as
/// the active source; switching to another source only tears down that bridge,
/// so this pipeline keeps receiving (silently) and can be reconnected later.
@MainActor
@Observable
final class AirPlayReceiverProcessManager {
    static let bonjourName = "AntennaHead"

    private let controller = AirPlayReceiverController(
        configuration: .init(deviceName: AirPlayReceiverProcessManager.bonjourName, udpPort: 0))

    var isRunning: Bool { controller.isRunning }
    var lastError: Error? { controller.lastError }

    init() {
        controller.onLog = { source, message in
            LogStore.shared.log(.info, source: source, message)
        }
    }

    func start(deviceName: String, udpPort: UInt16) {
        let wasRunning = controller.isRunning
        controller.updateConfiguration(.init(deviceName: deviceName, udpPort: udpPort))
        // updateConfiguration() already restarts the pipeline when wasRunning; calling
        // start() again would stop and relaunch it a second time, racing on port 5000.
        if !wasRunning {
            controller.start()
        }
    }

    func stop() {
        controller.stop()
    }
}
