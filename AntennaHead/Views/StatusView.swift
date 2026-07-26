import SwiftUI
import PipelineRunner

/// Status tab, rendered entirely as a web view. Data items are presented as
/// HTML; the RTL-SDR task pipeline is drawn as an inline SVG flow diagram.
/// The view rebuilds a `StatusSnapshot` from the observable controllers and
/// hands it to `StatusWebView`, which pushes it into the page.
struct StatusView: View {
    var sdrController: SDRController
    var audioServer: LiveAudioServerClient

    var body: some View {
        StatusWebView(snapshot: snapshot)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Builds the snapshot from current controller state. Reading the observable
    /// properties here ties the view's updates to tuning, pipeline, and stream
    /// changes, so `StatusWebView` is re-pushed whenever any of them change.
    private var snapshot: StatusSnapshot {
        let active = sdrController.taskMode != .stopped

        var snap = StatusSnapshot(
            serverRunning: audioServer.isRunning,
            listenerCount: audioServer.listenerCount,
            statusFunction: sdrController.statusFunction,
            stationName: sdrController.stationName,
            frequencyDisplay: sdrController.frequencyDisplay,
            modulation: sdrController.modulation.uppercased(),
            samplingMode: active ? (sdrController.directSamplingQBranch ? "Direct sampling (Q-branch)" : "Standard") : "",
            squelchLevel: active ? "\(sdrController.squelchLevel)" : "",
            tunerGain: active ? String(format: "%g dB", sdrController.tunerGain) : "",
            tunerAGC: sdrController.tunerAGC,
            sampleRate: active && sdrController.sampleRate > 0 ? "\(sdrController.sampleRate) Hz" : "",
            audioOutputFilter: sdrController.audioOutputFilter,
            options: sdrController.options
        )
        snap.stages = pipelineStages()
        snap.signalLevel = normalizedSignal(sdrController.signalLevel)
        snap.pipelineLastStarted = Self.timeString(sdrController.radioTaskPipelineManager.lastStartedAt)
        snap.pipelineLastStopped = Self.timeString(sdrController.radioTaskPipelineManager.lastStoppedAt)
        return snap
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static func timeString(_ date: Date?) -> String {
        guard let date else { return "" }
        return timeFormatter.string(from: date)
    }

    /// Maps rtl_fm's raw RMS signal level (0–32767, int16 full scale) to the
    /// meter's 0–1 range on a dBFS scale: −60 dBFS reads empty, 0 dBFS reads full.
    private func normalizedSignal(_ rms: Int) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20.0 * log10(Double(rms) / 32767.0)   // ≤ 0
        let floorDB = -60.0
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }

    /// Maps the live pipeline's task items into renderable stages, then appends
    /// the LiveAudioServer sink the terminal PCMUDPSender feeds over UDP.
    private func pipelineStages() -> [StatusSnapshot.Stage] {
        let items = sdrController.radioTaskPipelineManager.taskItems
        guard !items.isEmpty else { return [] }

        var stages: [StatusSnapshot.Stage] = items.enumerated().map { index, item in
            let pid = item.process?.processIdentifier ?? 0
            let running = item.process?.isRunning ?? false
            return StatusSnapshot.Stage(
                name: item.functionName,
                detail: running ? "PID \(pid)" : "stopped",
                path: item.path,
                args: item.argsArray,
                running: running,
                link: index == 0 ? "" : "pipe"
            )
        }

        stages.append(StatusSnapshot.Stage(
            name: "LiveAudioServer",
            detail: audioServer.isRunning ? "live" : "offline",
            path: "UDP PCM input → HTTP/AAC stream",
            args: [],
            running: audioServer.isRunning,
            link: "UDP :\(sdrController.udpInputPort)"
        ))
        return stages
    }
}
