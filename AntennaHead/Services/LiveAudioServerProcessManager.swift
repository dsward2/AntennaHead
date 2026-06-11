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
    }

    /// Env var name used to pass the password to LAS via --auth-password-env so
    /// it never appears in argv (and hence not in `ps`).
    private static let authPasswordEnvVar = "ANTENNAHEAD_LAS_AUTH_PASSWORD"

    private static let executablePathKey = "AntennaHead.liveAudioServer.executablePath"

    private(set) var isRunning = false
    private(set) var lastError: Error?

    private var process: Process?
    private var userInitiatedStop = false

    var executableURL: URL {
        get {
            if let override = UserDefaults.standard.string(forKey: Self.executablePathKey),
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/LiveAudioServer")
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: Self.executablePathKey)
        }
    }

    func start(auth: HTTPAuthCredentials.Credentials?, tls: TLSConfig?) {
        stop()
        let url = executableURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            lastError = LASError.executableMissing(url.path)
            print("LiveAudioServerProcessManager: executable missing at \(url.path)")
            return
        }

        var args: [String] = []
        if let tls {
            args.append(contentsOf: ["--tls-identity", tls.identityPath,
                                     "--tls-password", tls.password])
        }
        if let auth {
            args.append(contentsOf: [
                "--auth-user", auth.user,
                "--auth-realm", auth.realm,
                "--auth-password-env", Self.authPasswordEnvVar
            ])
        }

        let proc = Process()
        proc.executableURL = url
        proc.arguments = args

        var environment = ProcessInfo.processInfo.environment
        if let auth {
            environment[Self.authPasswordEnvVar] = auth.password
        } else {
            environment.removeValue(forKey: Self.authPasswordEnvVar)
        }
        proc.environment = environment

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasUserInitiated = self.userInitiatedStop
                self.userInitiatedStop = false
                self.isRunning = false
                self.process = nil
                if !wasUserInitiated {
                    print("LiveAudioServerProcessManager: subprocess exited unexpectedly with status \(terminated.terminationStatus)")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.isRunning = true
            self.lastError = nil
        } catch {
            self.lastError = LASError.launchFailed("\(error)")
            print("LiveAudioServerProcessManager: \(error)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            isRunning = false
            return
        }
        userInitiatedStop = true
        proc.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
        isRunning = false
    }

    func restart(auth: HTTPAuthCredentials.Credentials?, tls: TLSConfig?) {
        start(auth: auth, tls: tls)
    }
}
