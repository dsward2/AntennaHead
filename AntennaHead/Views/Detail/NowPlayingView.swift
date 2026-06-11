import SwiftUI

struct NowPlayingView: View {
    var frequency: Frequency?
    var audioServer: LiveAudioServerClient

    var body: some View {
        if let frequency {
            VStack(spacing: 0) {
                StationHeaderView(frequency: frequency)
                Divider()
                SignalMeterView()
                    .padding()
                Divider()
                PlaybackControlsView(frequency: frequency, audioServer: audioServer)
                    .padding()
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
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Playback").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 24) {
                Button(isPlaying ? "Stop" : "Play",
                       systemImage: isPlaying ? "stop.fill" : "play.fill") {
                    isPlaying.toggle()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Spacer()

                Button("Record", systemImage: "record.circle") {}
                    .buttonStyle(.bordered)
                    .disabled(!isPlaying)
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
