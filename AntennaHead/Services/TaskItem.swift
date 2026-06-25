import Foundation
import Observation

@MainActor
@Observable
final class TaskItem {
    enum TaskItemError: Error, CustomStringConvertible {
        case notConfigured
        case launchFailed(String)

        var description: String {
            switch self {
            case .notConfigured: return "TaskItem has no Process to launch — call createTask() first."
            case .launchFailed(let m): return "TaskItem launch failed: \(m)"
            }
        }
    }

    let functionName: String
    var path: String
    private(set) var argsArray: [String] = []
    private(set) var process: Process?
    private(set) var stderrPipe: Pipe?
    private(set) var lastTerminationStatus: Int32?
    private(set) var lastTerminationReason: Process.TerminationReason?

    init(path: String, functionName: String) {
        self.path = path
        self.functionName = functionName
    }

    func addArgument(_ arg: String) {
        argsArray.append(arg)
    }

    func addArgument<T: Numeric>(_ number: T) {
        argsArray.append("\(number)")
    }

    func quotedPath() -> String {
        return path
    }

    func argsString() -> String {
        argsArray.map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }

    func createTask() {
        lastTerminationStatus = nil
        lastTerminationReason = nil

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = argsArray

        task.terminationHandler = { [weak self] terminated in
            let pid = terminated.processIdentifier
            let status = terminated.terminationStatus
            let reason = terminated.terminationReason
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("TaskItem PID=\(pid) - \(self.path) terminationHandler status=\(status) reason=\(reason.rawValue)")
                self.lastTerminationStatus = status
                self.lastTerminationReason = reason
                self.process = nil
            }
        }

        self.process = task
    }

    func start() throws {
        guard let task = process else {
            throw TaskItemError.notConfigured
        }
        do {
            try task.run()
            print("TaskItem - Launched Process PID=\(task.processIdentifier), \(path) \(argsString())")
        } catch {
            throw TaskItemError.launchFailed("\(error)")
        }
    }

    func terminate() {
        guard let task = process, task.isRunning else {
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe = nil
            process = nil
            return
        }
        task.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
        }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        process = nil
    }

    func taskInfoString() -> String {
        let pid = process?.processIdentifier ?? 0
        let runningFlag = (process?.isRunning ?? false) ? 1 : 0
        return "\(functionName) -  process ID = \(pid) -  isRunning = \(runningFlag)\n\n\"\(path)\" \(argsString())\n\n"
    }
}
