import SwiftUI

struct NowPlayingView: View {
    var frequency: Frequency?
    var audioServer: LiveAudioServerClient
    var sdrController: SDRController

    var body: some View {
        if let frequency {
            VStack(spacing: 0) {
                StationHeaderView(frequency: frequency)
                Divider()
                SignalMeterView()
                    .padding()
                Divider()
                PlaybackControlsView(frequency: frequency,
                                     audioServer: audioServer,
                                     sdrController: sdrController)
                    .padding()
                if sdrController.spatialAudioEnabled {
                    Divider()
                    SpatialPositionView(sdrController: sdrController)
                        .padding()
                }
                Divider()
                StreamStatusView(audioServer: audioServer)
                    .padding()
                Spacer()
            }
            .navigationTitle(frequency.stationName)
        } else {
            ContentUnavailableView("Select a Station", systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}

struct StationHeaderView: View {
    var frequency: Frequency

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(frequency.stationName)
                    .font(.title2.bold())
                Text(frequency.formattedFrequency)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(frequency.modulation.uppercased())
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
            Spacer()
        }
        .padding()
    }
}

struct PlaybackControlsView: View {
    var frequency: Frequency
    var audioServer: LiveAudioServerClient
    var sdrController: SDRController
    @State private var actionError: String?

    /// This station is live when the SDR pipeline is tuned to its record id.
    private var isPlaying: Bool {
        frequency.id != nil && sdrController.activeFrequencyID == frequency.id
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Playback").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 24) {
                Button(isPlaying ? "Stop" : "Play",
                       systemImage: isPlaying ? "stop.fill" : "play.fill") {
                    togglePlayback()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Spacer()

                Button("Record", systemImage: "record.circle") {}
                    .buttonStyle(.bordered)
                    .disabled(!isPlaying)
            }
            if let message = actionError ?? sdrController.lastError.map({ "\($0)" }) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func togglePlayback() {
        actionError = nil
        if isPlaying {
            sdrController.terminateTasks()
        } else if let id = frequency.id {
            do {
                try sdrController.startTasksForFrequency(id: id)
            } catch {
                actionError = "\(error)"
            }
        }
    }
}

/// Live distance control for the optional `PCMDistanceGain` pipeline stage
/// (see Configuration → Spatial Audio). Dragging sends a `dist <value>`
/// update straight to the running stage's control port — no pipeline
/// restart, no round trip through ControlBooth.
///
/// `@Bindable` (not the plain `var` the sibling views use) because this is
/// the one control here that needs a two-way `Slider` binding into the
/// `@Observable` controller rather than a one-shot method call.
struct SpatialPositionView: View {
    @Bindable var sdrController: SDRController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spatial Position").font(.headline)
            HStack {
                Text("Distance")
                    .foregroundStyle(.secondary)
                Slider(value: $sdrController.spatialDistance, in: 0.1...4.0)
                Text(String(format: "%.2f", sdrController.spatialDistance))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

struct StreamStatusView: View {
    var audioServer: LiveAudioServerClient

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Stream").font(.headline)
                Spacer()
                Circle()
                    .fill(audioServer.isRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(audioServer.isRunning ? "Live" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("\(audioServer.listenerCount) listener\(audioServer.listenerCount == 1 ? "" : "s")",
                      systemImage: "person.2")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
