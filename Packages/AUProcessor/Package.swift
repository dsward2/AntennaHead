// swift-tools-version: 5.9
import PackageDescription

// AUProcessor — Audio Unit effect stage of an AntennaHead audio pipeline.
//
// Hosts one installed Audio Unit effect (Apple built-ins like AUGraphicEQ or
// AUDynamicsProcessor, or third-party plugins) in an AVAudioEngine running in
// offline manual-rendering mode, streaming S16LE PCM stdin → effect → stdout.
// As a mid-pipeline stage it adds no pacing — upstream clocks it, like sox.
// Parameters are set headlessly: --param / --preset at launch, or a UDP
// control port while running.
let package = Package(
    name: "AUProcessor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AUProcessor", targets: ["AUProcessor"])
    ],
    targets: [
        .executableTarget(name: "AUProcessor")
    ]
)
