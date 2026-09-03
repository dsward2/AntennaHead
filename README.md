# AntennaHead

A macOS app for software-defined radio (SDR) streaming. It tunes an RTL-SDR USB device, demodulates FM/AM/HD Radio signals, and streams audio to a web browser via a built-in HTTP/HTTPS server powered by [LiveAudioServer](https://github.com/dsward2/LiveAudioServer). The web UI (based on LocalRadio) runs on any device on the local network.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- An RTL-SDR USB dongle (optional — audio device and custom-task sources work without one)

## Dependencies

All dependencies are resolved by Swift Package Manager when the project is opened in Xcode:

| Package | Purpose |
|---|---|
| [GRDB](https://github.com/groue/GRDB.swift) | SQLite database (frequencies, categories, settings) |
| [LiveAudioServer](https://github.com/dsward2/LiveAudioServer) | Embedded streaming server (AAC/HLS over HTTP/HTTPS) |
| [PipelineHelpers](https://github.com/dsward2/PipelineHelpers) | Pipeline runner shared with ControlBooth |
| [SharedLogging](https://github.com/dsward2/SharedLogging) | Shared log store + viewer window shared with ControlBooth |
| [librtlsdr](https://github.com/dsward2/librtlsdr) | RTL-SDR driver (XCFramework) |
| [swift-certificates](https://github.com/apple/swift-certificates) | TLS certificate generation |
| [swift-asn1](https://github.com/apple/swift-asn1) | ASN.1 / DER encoding (for PKCS#12 export) |
| [swift-crypto](https://github.com/apple/swift-crypto) | P-256 key generation for self-signed TLS certs |

The LiveAudioServer helper binary is also **vendored** at `AntennaHead/LiveAudioServer` for use as a subprocess; refresh it manually when updating the LAS package.

**LiveAudioServer, PipelineHelpers, and SharedLogging are
local Swift packages**, referenced by relative path (`../LiveAudioServer`,
`../PipelineHelpers`, `../SharedLogging`) rather than by
URL — Xcode can only resolve them if this repo is checked out with those three
as sibling directories. The [antennahead-workspace](https://github.com/dsward2/antennahead-workspace)
umbrella project's `bootstrap.sh` sets up exactly that layout; use it instead
of cloning this repo standalone if you plan to build from source rather than
just consuming released binaries.

## Build

1. Clone the repo:
   ```
   git clone https://github.com/dsward2/AntennaHead.git
   cd AntennaHead
   ```
2. Open `AntennaHead.xcodeproj` in Xcode.
3. Select the **AntennaHead** scheme and your Mac as the destination.
4. Build and run (`⌘R`).

SPM dependencies are fetched automatically on first build. No `brew` or manual tooling is required.

## Default Ports

| Service | Protocol | Default Port |
|---|---|---|
| AntennaHead web UI | HTTP | 8090 |
| AntennaHead web UI | HTTPS | 8094 |
| LiveAudioServer stream | HTTP | 8080 |
| LiveAudioServer stream | HTTPS | 8443 |
| RTL-SDR status feed | UDP | 6021 |
| Pipeline audio input | UDP | 6020 |
| ControlBooth audio input | UDP | 6019 |
| Speech-to-text caption feed | UDP | 6023 |

All ports are configurable from the **Configuration** tab → **Change Configuration…** sheet, except the speech-to-text caption feed, which is a fixed constant not exposed in that sheet. Changes restart the streaming servers.

## Features

- **Web UI** — Full-featured LocalRadio-compatible web interface accessible from any browser on the LAN. Supports favorites, categories, frequency tuner, audio devices, and custom pipeline tasks.
- **FM / AM / HD Radio** — Demodulates signals via `rtl_fm` and optional stereo demux helper.
- **Audio devices** — Stream from any Core Audio input device as an audio source.
- **Custom tasks** — Define arbitrary shell pipelines (via PipelineHelpers) as audio sources.
- **HTTPS** — Optional TLS with auto-generated self-signed cert or a user-supplied `.p12`. Toggle on/off in the **Security** tab without discarding the certificate.
- **HTTP Authentication** — Optional username/password protection forwarded to LiveAudioServer.
- **FCC search** — Look up US broadcast stations by frequency or call sign.
- **ControlBooth** — Optional bidirectional Apple Events remote-control channel. See [Docs/AppleEvents.md](Docs/AppleEvents.md).

## ControlBooth Integration

AntennaHead can be remotely controlled by the companion [ControlBooth](https://github.com/dsward2/ControlBooth) app over a bidirectional Apple Events channel. Enable the integration in the **Configuration** tab. See [Docs/AppleEvents.md](Docs/AppleEvents.md) for the full protocol description.

## Architecture Notes

- The app is **sandboxed**. Helper processes (`LiveAudioServer`, `rtl_fm`, stereodemux) are launched as child processes with `--exit-with-parent` watchdogs so they are reaped if the parent exits.
- The web server and all DB access run on the `@MainActor`. Nonisolated network routing dispatches back to the main actor for any state access.
- Port and bitrate settings are persisted in a SQLite database (Application Support/AntennaHead/).
- TLS certificates are stored in the macOS keychain and exported to a PKCS#12 file for the LiveAudioServer subprocess.

## License

See individual source files and [Web/credits.html](AntennaHead/Web/credits.html) for third-party credits and licenses.
