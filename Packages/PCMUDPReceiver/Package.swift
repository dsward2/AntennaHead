// swift-tools-version: 5.9
import PackageDescription

// PCMUDPReceiver — source stage of an AntennaHead audio pipeline.
//
// The inverse of PCMUDPSender: listens on --port for UDP datagrams and writes
// their payloads to stdout, feeding the rest of a custom-task pipeline. This
// lets external, unsigned tools that can't be bundled (e.g. nrsc5) run outside
// the app and hand their audio to AntennaHead over loopback UDP — no
// code-signing entanglement, no socat.
//
// Output contract: whatever the sender transmits — typically raw signed 16-bit
// little-endian PCM that a downstream sox stage normalizes to 48000 Hz stereo.
let package = Package(
    name: "PCMUDPReceiver",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PCMUDPReceiver", targets: ["PCMUDPReceiver"])
    ],
    targets: [
        .executableTarget(name: "PCMUDPReceiver")
    ]
)
