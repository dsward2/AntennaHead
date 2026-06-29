// swift-tools-version: 5.9
import PackageDescription

// PCMUDPSender — terminal stage of an AntennaHead audio pipeline.
//
// Mirrors the PCMPassthrough template, but instead of writing PCM to stdout it
// sends it as UDP datagrams to a LiveAudioServer instance listening on
// --udp-input-port. This decouples the radio pipeline from the streaming
// server: LiveAudioServer can run continuously (holding the client's HTTP
// connection alive with filler) while the pipeline feeding it is freely torn
// down and rebuilt on retune.
//
// Input contract (shared by every pipeline unit): raw signed 16-bit
// little-endian, mono, 48000 Hz PCM on stdin.
let package = Package(
    name: "PCMUDPSender",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PCMUDPSender", targets: ["PCMUDPSender"])
    ],
    targets: [
        .executableTarget(name: "PCMUDPSender")
    ]
)
