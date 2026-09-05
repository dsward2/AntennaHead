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

/// Live position controls for the optional `PCMDistanceGain` +
/// `PCMBinauralPanner` pipeline stages (see Configuration → Spatial Audio).
/// Dragging sends the matching control-port update straight to the running
/// stage — no pipeline restart, no round trip through ControlBooth.
///
/// `@Bindable` (not the plain `var` the sibling views use) because this is
/// the one view here that needs two-way `Slider` bindings into the
/// `@Observable` controller rather than one-shot method calls.
struct SpatialPositionView: View {
    @Bindable var sdrController: SDRController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spatial Position").font(.headline)
            positionRow("Azimuth", value: $sdrController.azimuth, range: -180...180,
                        format: "%.0f\u{00B0}")
            positionRow("Elevation", value: $sdrController.elevation, range: -90...90,
                        format: "%.0f\u{00B0}")
            positionRow("Distance", value: $sdrController.spatialDistance, range: 0.1...4.0,
                        format: "%.2f")
        }
    }

    private func positionRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                             format: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
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
