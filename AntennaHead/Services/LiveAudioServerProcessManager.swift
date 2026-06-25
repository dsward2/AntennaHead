import Foundation
import Observation

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

    /// Default tuning used until station selection is wired up (database work).
    /// rtl_fm produces mono PCM, so LiveAudioServer is started with --channels 1.
    private static let defaultFrequencyHz = 89_100_000
    private static let defaultModulation = "fm"
    private static let audioSampleRate = 48_000

    private(set) var isRunning = false
    private(set) var lastError: Error?

    /// The LiveAudioServer (streaming/HTTP) process.
    private var serverProcess: Process?
    /// The rtl_fm radio source feeding the server's stdin.
    private var sourceProcess: Process?
    private var userInitiatedStop = false

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

    /// rtl_fm radio source helper, embedded alongside LiveAudioServer.
    private var sourceExecutableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/rtl_fm_localradio")
    }

    func start(auth: HTTPAuthCredentials.Credentials?, tls: TLSConfig?) {
        stop()

        let serverURL = executableURL
        let sourceURL = sourceExecutableURL
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: serverURL.path) else {
            lastError = LASError.executableMissing(serverURL.path)
            print("LiveAudioServerProcessManager: executable missing at \(serverURL.path)")
            return
        }
        guard fm.isExecutableFile(atPath: sourceURL.path) else {
            lastError = LASError.executableMissing(sourceURL.path)
            print("LiveAudioServerProcessManager: radio source missing at \(sourceURL.path)")
            return
        }

        // LiveAudioServer reads mono PCM from stdin to match rtl_fm's output.
        var serverArgs: [String] = [
            "--rate", "\(Self.audioSampleRate)",
            "--channels", "1"
        ]
        if let tls {
            serverArgs.append(contentsOf: ["--tls-identity", tls.identityPath,
                                           "--tls-password", tls.password,
                                           "--tls-port", "\(tls.port)"])
        }
        if let auth {
            serverArgs.append(contentsOf: [
                "--auth-user", auth.user,
                "--auth-realm", auth.realm,
                "--auth-password-env", Self.authPasswordEnvVar
            ])
        }

        // rtl_fm radio source: tune, demodulate, emit PCM on stdout.
        let sourceArgs: [String] = [
            "-f", "\(Self.defaultFrequencyHz)",
            "-M", Self.defaultModulation,
            "-s", "200000",
            "-r", "\(Self.audioSampleRate)",
            "-"
        ]

        // Pipe rtl_fm stdout -> LiveAudioServer stdin.
        let audioPipe = Pipe()

        let source = Process()
        source.executableURL = sourceURL
        source.arguments = sourceArgs
        source.standardInput = FileHandle.nullDevice
        source.standardOutput = audioPipe
        source.standardError = FileHandle.standardError

        let server = Process()
        server.executableURL = serverURL
        server.arguments = serverArgs
        server.standardInput = audioPipe
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.standardError

        var environment = ProcessInfo.processInfo.environment
        if let auth {
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
                // If the server dies on its own, tear the radio source down too.
                if let src = self.sourceProcess, src.isRunning {
                    src.terminate()
                }
                self.sourceProcess = nil
                if !wasUserInitiated {
                    print("LiveAudioServerProcessManager: server exited unexpectedly with status \(terminated.terminationStatus)")
                }
            }
        }

        do {
            try source.run()
            try server.run()
            self.sourceProcess = source
            self.serverProcess = server
            self.isRunning = true
            self.lastError = nil
        } catch {
            self.lastError = LASError.launchFailed("\(error)")
            print("LiveAudioServerProcessManager: \(error)")
            if source.isRunning { source.terminate() }
            if server.isRunning { server.terminate() }
            self.sourceProcess = nil
            self.serverProcess = nil
            self.isRunning = false
        }
    }

    func stop() {
        let running = (serverProcess?.isRunning ?? false) || (sourceProcess?.isRunning ?? false)
        guard running else {
            serverProcess = nil
            sourceProcess = nil
            isRunning = false
            return
        }
        userInitiatedStop = true
        // Stop the source first so the server sees stdin EOF and can flush.
        terminate(sourceProcess)
        terminate(serverProcess)
        serverProcess = nil
        sourceProcess = nil
        isRunning = false
    }

    /// Terminates a process, escalating to SIGKILL if it does not exit promptly.
    private func terminate(_ proc: Process?) {
        guard let proc, proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    func restart(auth: HTTPAuthCredentials.Credentials?, tls: TLSConfig?) {
        start(auth: auth, tls: tls)
    }
}
