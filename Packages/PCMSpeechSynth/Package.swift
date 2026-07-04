// swift-tools-version: 5.9
import PackageDescription

// PCMSpeechSynth — text-to-speech source stage of an AntennaHead audio pipeline.
//
// Renders text to PCM offline with AVSpeechSynthesizer (no audio device) and
// writes S16LE mono to stdout, paced in real time so downstream UDP sinks
// aren't flooded. Text comes from stdin, a file, or a UDP port (each datagram
// replaces the current text); --repeat loops the announcement continuously
// with a configurable silence gap.
let package = Package(
    name: "PCMSpeechSynth",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PCMSpeechSynth", targets: ["PCMSpeechSynth"])
    ],
    targets: [
        .executableTarget(name: "PCMSpeechSynth")
    ]
)
