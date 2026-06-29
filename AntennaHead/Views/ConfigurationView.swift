import SwiftUI

struct ConfigurationView: View {
    var sdrController: SDRController
    var audioServer: LiveAudioServerClient

    @State private var selectedCategory: Category?
    @State private var selectedStation: Frequency?
    @State private var refreshID = UUID()

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedCategory: $selectedCategory, refreshID: refreshID)
        } content: {
            StationListView(category: selectedCategory, selectedStation: $selectedStation, refreshID: $refreshID)
        } detail: {
            NowPlayingView(frequency: selectedStation,
                           audioServer: audioServer,
                           sdrController: sdrController)
        }
    }
}

struct DeviceSettingsDetailView: View {
    @State private var selectedDevice = "RTL-SDR v3"
    @State private var gain: Double = 40
    @State private var ppmCorrection: Double = 0
    @State private var squelch: Double = 0
    @State private var useDirectSampling = false

    private let devices = ["RTL-SDR v3", "RTL-SDR Blog v4", "Generic RTL2832U"]

    var body: some View {
        Form {
            Section("Device") {
                Picker("RTL-SDR Device", selection: $selectedDevice) {
                    ForEach(devices, id: \.self) { Text($0) }
                }
            }
            Section("Tuner") {
                HStack {
                    Text("Gain")
                    Slider(value: $gain, in: 0...50, step: 1)
                    Text("\(Int(gain)) dB")
                        .monospacedDigit()
                        .frame(width: 50)
                }
                HStack {
                    Text("PPM Correction")
                    Slider(value: $ppmCorrection, in: -100...100, step: 1)
                    Text("\(Int(ppmCorrection))")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                HStack {
                    Text("Squelch")
                    Slider(value: $squelch, in: 0...100, step: 1)
                    Text("\(Int(squelch))")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Toggle("Direct Sampling (AM/Shortwave)", isOn: $useDirectSampling)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Device Settings")
    }
}
