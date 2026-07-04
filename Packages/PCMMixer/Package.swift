// swift-tools-version: 5.9
import PackageDescription

// PCMMixer — N-input PCM mixing stage of an AntennaHead audio pipeline.
//
// Mixes two or more S16LE PCM streams (stdin and/or UDP ports) into one
// output (stdout or UDP), with a UDP control port for adjusting per-input
// gains / the 2-input crossfade ratio while running. sox's `-m` can mix, but
// its volumes are fixed at launch; this helper exists for dynamic control.
//
// All inputs must share the same sample rate and channel count (normalize
// upstream with sox); mixing is sample-wise with saturation.
let package = Package(
    name: "PCMMixer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PCMMixer", targets: ["PCMMixer"])
    ],
    targets: [
        .executableTarget(name: "PCMMixer")
    ]
)
