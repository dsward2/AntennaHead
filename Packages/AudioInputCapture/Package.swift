// swift-tools-version: 5.9
import PackageDescription

// AudioInputCapture — front-end source stage for AntennaHead's device-input path.
//
// Captures a named Core Audio input device via AVAudioEngine, converts to the
// pipeline's contract (raw signed 16-bit little-endian, interleaved, 48000 Hz,
// 2-channel PCM), and writes it to stdout. Front-end normalization to 48 kHz
// means downstream sox only applies the audio_output_filter (no resample).
//
// Pipeline role (mirrors LocalRadio's AudioMonitor2):
//   AudioInputCapture  →  sox (filter)  →  PCMUDPSender  --udp-->  LiveAudioServer
let package = Package(
    name: "AudioInputCapture",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AudioInputCapture", targets: ["AudioInputCapture"])
    ],
    targets: [
        .executableTarget(name: "AudioInputCapture")
    ]
)
