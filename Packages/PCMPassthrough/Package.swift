// swift-tools-version: 5.9
import PackageDescription

// PCMPassthrough — template for an AntennaHead audio-pipeline stage.
//
// Each pipeline unit is its own local Swift package exposing a single
// executable product. The app embeds the built executable in
// Contents/Helpers and inserts it into the rtl_fm -> ... -> LiveAudioServer
// chain. Clone this package per filter and replace the passthrough body with
// your DSP, keeping the same raw-PCM stdin -> stdout contract.
let package = Package(
    name: "PCMPassthrough",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PCMPassthrough", targets: ["PCMPassthrough"])
    ],
    targets: [
        .executableTarget(name: "PCMPassthrough")
    ]
)
