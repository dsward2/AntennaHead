import SwiftUI

struct StatusView: View {
    var audioServer: LiveAudioServerClient
    @State private var selectedFrequency: Frequency?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            if let frequency = selectedFrequency {
                StationHeaderView(frequency: frequency)
                Divider()
            }

            ScrollView {
                VStack(spacing: 16) {
                    GroupBox("Signal") {
                        SignalMeterView()
                            .padding(.vertical, 4)
                    }

                    GroupBox("Playback") {
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
                        .padding(.vertical, 4)
                    }

                    GroupBox("Stream") {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Server")
                                Spacer()
                                Circle()
                                    .fill(audioServer.isRunning ? .green : .red)
                                    .frame(width: 8, height: 8)
                                Text(audioServer.isRunning ? "Live" : "Offline")
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Label("\(audioServer.listenerCount) listener\(audioServer.listenerCount == 1 ? "" : "s")",
                                      systemImage: "person.2")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
