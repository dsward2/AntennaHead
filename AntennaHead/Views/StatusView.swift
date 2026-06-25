import SwiftUI

struct StatusView: View {
    var audioServer: LiveAudioServerClient
    @State private var selectedFrequency: Frequency?
    @State private var isPlaying = false

    @State private var testFrequencyMHz: String = "89.1"
    @State private var testPipeline: TaskPipelineManager?
    @State private var testStatus: String = ""
    private let testPort = 8081
    private var testStreamURL: URL {
        URL(string: "http://localhost:\(testPort)/stream.mp3")!
    }

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

                    GroupBox("FM Test (mono, port \(testPort))") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Frequency (MHz):")
                                TextField("89.1", text: $testFrequencyMHz)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                                    .disabled(testPipeline != nil)
                            }
                            HStack(spacing: 12) {
                                Button(testPipeline == nil ? "Start" : "Stop",
                                       systemImage: testPipeline == nil ? "play.fill" : "stop.fill") {
                                    if testPipeline == nil { startFMTest() } else { stopFMTest() }
                                }
                                .buttonStyle(.borderedProminent)
                                if testPipeline != nil {
                                    Link("Open stream", destination: testStreamURL)
                                }
                                Spacer()
                            }
                            if !testStatus.isEmpty {
                                Text(testStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
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

    private func startFMTest() {
        guard testPipeline == nil else { return }
        guard let mhz = Double(testFrequencyMHz), mhz > 0 else {
            testStatus = "Invalid frequency."
            return
        }

        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let rtlPath = helpers.appendingPathComponent("rtl_fm_localradio").path
        let lasPath = helpers.appendingPathComponent("LiveAudioServer").path
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: rtlPath) else {
            testStatus = "Helper missing: \(rtlPath)"
            return
        }
        guard fm.isExecutableFile(atPath: lasPath) else {
            testStatus = "Helper missing: \(lasPath)"
            return
        }

        let pipeline = TaskPipelineManager()

        let rtl = pipeline.makeTaskItem(pathToExecutable: rtlPath, functionName: "rtl_fm")
        rtl.addArgument("-f"); rtl.addArgument("\(mhz)M")
        rtl.addArgument("-M"); rtl.addArgument("fm")
        rtl.addArgument("-s"); rtl.addArgument("200000")
        rtl.addArgument("-r"); rtl.addArgument("48000")
        rtl.addArgument("-")
        pipeline.add(rtl)

        let las = pipeline.makeTaskItem(pathToExecutable: lasPath, functionName: "LiveAudioServer")
        las.addArgument("--rate"); las.addArgument("48000")
        las.addArgument("--channels"); las.addArgument("1")
        las.addArgument("-p"); las.addArgument("\(testPort)")
        pipeline.add(las)

        do {
            try pipeline.start()
            testPipeline = pipeline
            testStatus = "Running. Stream: \(testStreamURL.absoluteString)"
        } catch {
            testStatus = "Start failed: \(error)"
        }
    }

    private func stopFMTest() {
        testPipeline?.terminate()
        testPipeline = nil
        testStatus = "Stopped."
    }
}
