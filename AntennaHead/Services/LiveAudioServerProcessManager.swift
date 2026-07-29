import Foundation
import Observation

/// Manages the LiveAudioServer (LAS) helper process.
///
/// LAS runs **continuously and decoupled** from the radio pipeline: it listens
/// for raw PCM on a UDP input port and holds the client's HTTP audio connection
/// alive (playing filler/silence) whenever no audio is arriving. The radio
/// pipeline built by `SDRController`/`TaskPipelineManager` ends in a UDP sender
/// that targets `udpInputPort`, so the pipeline can be torn down and rebuilt on
/// retune without ever dropping a listener.
@MainActor
@Observable
final class LiveAudioServerProcessManager {
    enum LASError: Error, CustomStringConvertible {
        case executableMissing(String)
        case launchFailed(String)

        var description: String {
            switch self {
            case .executableMissing(let path): return "LiveAudioServer executable not found at \(path)."
            case .launchFailed(let m): return "LiveAudioServer launch failed: \(m)"
            }
        }
    }

    struct TLSConfig {
        let identityPath: String
        let password: String
        var port: Int = 8443
    }

    /// Env var name used to pass the password to LAS via --auth-password-env so
    /// it never appears in argv (and hence not in `ps`).
    private static let authPasswordEnvVar = "ANTENNAHEAD_LAS_AUTH_PASSWORD"

    private static let executablePathKey = "AntennaHead.liveAudioServer.executablePath"

    /// PCM format LAS expects on its UDP input. Must match the pipeline's
    /// terminal format (sox normalize -> PCMUDPSender): S16LE 2-channel 48k.
    /// The pipeline always emits 2 channels (mono upmixed to dual-mono;
    /// FM-stereo decoded to L/R), so this format is constant across retunes.
    private static let audioSampleRate = 48_000
    private static let audioChannels = 2

    /// HTTP port LiveAudioServer listens on for its web UI. Updated from
    /// `PortSettings` on each `start(...)`.
    private(set) var httpPort = 8080

    /// UDP port LAS listens on for incoming PCM. `SDRController` points its
    /// PCMUDPSender stage at this port. Updated from `PortSettings` on start.
    static let defaultUDPInputPort: UInt16 = 6020
    private(set) var udpInputPort: UInt16 = LiveAudioServerProcessManager.defaultUDPInputPort

    private(set) var isRunning = false
    private(set) var lastError: Error?

    /// The LiveAudioServer (streaming/HTTP) process.
    private var serverProcess: Process?
    private var userInitiatedStop = false
    /// Arguments passed to the last successful launch, for display in the Status view.
    private(set) var lastLaunchArgs: [String] = []
    /// Pending async launch; cancelled and replaced on each new `start()` call so
    /// rapid successive calls (e.g. two notifications firing back-to-back) never
    /// race to start two LAS instances simultaneously.
    private var startTask: Task<Void, Never>?

    /// Auth/TLS/bitrate/recording captured at last start so `restart()` can reapply them.
    private var currentAuth: HTTPAuthCredentials.Credentials?
    private var currentTLS: TLSConfig?
    private var currentOutputBitrate = 128_000
    private var currentRecordingPath: URL?

    /// Bonjour (mDNS) name LAS advertises its HTTP/HTTPS listeners under on
    /// the LAN (LAS `--bonjour`), so players can discover the audio stream.
    static let bonjourName = "AntennaHead Audio"

    var executableURL: URL {
        get {
            if let override = UserDefaults.standard.string(forKey: Self.executablePathKey),
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/LiveAudioServer")
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: Self.executablePathKey)
        }
    }

    /// Starts (or restarts) LiveAudioServer. Called at app launch and whenever
    /// auth/TLS/bitrate/port settings change. The radio pipeline is managed
    /// separately by `SDRController`, which never restarts LAS — so listeners
    /// survive retunes. `outputBitrate` (bits/sec) applies to both encoders.
    func start(auth: HTTPAuthCredentials.Credentials?, tls: TLSConfig?, outputBitrate: Int = 128_000,
               httpPort: UInt16 = 8080, udpInputPort: UInt16 = LiveAudioServerProcessManager.defaultUDPInputPort,
               recordingPath: URL? = nil) {
        // Capture any running process before stop() clears the reference, so the
        // async wait below can confirm port 8080/6020 are free before the new
        // instance tries to bind them.
        let dying = (serverProcess?.isRunning == true) ? serverProcess : nil
        stop()

        currentAuth = auth
        currentTLS = tls
        currentOutputBitrate = outputBitrate
        currentRecordingPath = recordingPath
        self.httpPort = Int(httpPort)
        self.udpInputPort = udpInputPort

        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if let dying {
                await Self.waitForExit(dying, timeout: 2.0)
                guard !Task.isCancelled else { return }
            }
            await HelperProcessPreflight.waitForUDPPortFree(self.udpInputPort)
            guard !Task.isCancelled else { return }
            await HelperProcessPreflight.waitForTCPPortFree(UInt16(self.httpPort))
            guard !Task.isCancelled else { return }
            if let tlsPort = self.currentTLS?.port {
                await HelperProcessPreflight.waitForTCPPortFree(UInt16(tlsPort))
                guard !Task.isCancelled else { return }
            }
            self.launchServer()
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        guard let proc = serverProcess, proc.isRunning else {
            serverProcess = nil
            isRunning = false
            return
        }
        userInitiatedStop = true
        proc.terminate()
        serverProcess = nil
        isRunning = false
        // Wait for graceful exit off the main thread; SIGKILL after 2 seconds if needed.
        Task.detached {
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    func restart(auth: HTTPAuthCredentials.Credentials?, tls: TLSConfig?) {
        // Delegate entirely to start(), which handles stop-then-wait internally.
        start(auth: auth, tls: tls, outputBitrate: currentOutputBitrate,
              httpPort: UInt16(httpPort), udpInputPort: udpInputPort,
              recordingPath: currentRecordingPath)
    }

    /// Non-blocking wait for a process to exit; SIGKILLs after the timeout.
    private static func waitForExit(_ proc: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func launchServer() {
        let serverURL = executableURL
        guard FileManager.default.isExecutableFile(atPath: serverURL.path) else {
            lastError = LASError.executableMissing(serverURL.path)
            print("LiveAudioServerProcessManager: executable missing at \(serverURL.path)")
            return
        }

        // Persistent UDP-input server: read mono PCM datagrams, emit silence
        // filler while idle so the client connection never drops on retune.
        // --exit-with-parent makes LAS reap itself if the app dies/crashes
        // (otherwise it orphans holding its HTTP port).
        var serverArgs: [String] = [
            "--port", "\(self.httpPort)",
            "--udp-input-port", "\(self.udpInputPort)",
            "--keep-alive",
            "--filler-mode", "silence",
            "--exit-with-parent",
            "--rate", "\(Self.audioSampleRate)",
            "--channels", "\(Self.audioChannels)",
            // LAS takes kbps; the setting is stored in bits/sec.
            "--mp3-bitrate", "\(currentOutputBitrate / 1000)",
            "--aac-bitrate", "\(currentOutputBitrate / 1000)",
            "--bonjour", Self.bonjourName
        ]
        if let recordingPath = currentRecordingPath {
            serverArgs.append(contentsOf: ["--record-aac", recordingPath.path])
        }
        if let tls = currentTLS {
            serverArgs.append(contentsOf: ["--tls-identity", tls.identityPath,
                                           "--tls-password", tls.password,
                                           "--tls-port", "\(tls.port)"])
        }
        if let auth = currentAuth {
            serverArgs.append(contentsOf: [
                "--auth-user", auth.user,
                "--auth-realm", auth.realm,
                "--auth-password-env", Self.authPasswordEnvVar
            ])
        }

        lastLaunchArgs = serverArgs

        let server = Process()
        server.executableURL = serverURL
        server.arguments = serverArgs
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.standardError

        var environment = ProcessInfo.processInfo.environment
        // Strip DYLD_* variables injected by Xcode (e.g. __preview.dylib for Swift Previews);
        // helper binaries crash with SIGABRT if they inherit DYLD_INSERT_LIBRARIES they can't load.
        for key in environment.keys where key.hasPrefix("DYLD_") { environment.removeValue(forKey: key) }
        if let auth = currentAuth {
            environment[Self.authPasswordEnvVar] = auth.password
        } else {
            environment.removeValue(forKey: Self.authPasswordEnvVar)
        }
        server.environment = environment

        server.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasUserInitiated = self.userInitiatedStop
                self.userInitiatedStop = false
                self.isRunning = false
                self.serverProcess = nil
                if !wasUserInitiated {
                    print("LiveAudioServerProcessManager: server exited unexpectedly with status \(terminated.terminationStatus)")
                }
            }
        }

        do {
            try server.run()
            self.serverProcess = server
            self.isRunning = true
            self.lastError = nil
        } catch {
            self.lastError = LASError.launchFailed("\(error)")
            print("LiveAudioServerProcessManager: \(error)")
            if server.isRunning { server.terminate() }
            self.serverProcess = nil
            self.isRunning = false
        }
    }

    /// Formats the LAS process state in the same layout as `TaskItem.taskInfoString()`,
    /// so it can be appended to the pipeline text dump in the Status view.
    func taskInfoString() -> String {
        let pid = serverProcess?.processIdentifier ?? 0
        let runningFlag = (serverProcess?.isRunning ?? false) ? 1 : 0
        let argsString = lastLaunchArgs.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        return "LiveAudioServer -  process ID = \(pid) -  isRunning = \(runningFlag)\n\n\"\(executableURL.path)\" \(argsString)\n\n"
    }

    /// Restarts LiveAudioServer with `--record-aac` pointed at `path`.
    func startRecording(at path: URL) {
        start(auth: currentAuth, tls: currentTLS, outputBitrate: currentOutputBitrate,
              httpPort: UInt16(httpPort), udpInputPort: udpInputPort,
              recordingPath: path)
    }

    /// Restarts LiveAudioServer without a recording output (stops the current recording).
    func stopRecording() {
        guard currentRecordingPath != nil else { return }
        start(auth: currentAuth, tls: currentTLS, outputBitrate: currentOutputBitrate,
              httpPort: UInt16(httpPort), udpInputPort: udpInputPort,
              recordingPath: nil)
    }
}
