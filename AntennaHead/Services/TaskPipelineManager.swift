import Foundation
import Observation

@MainActor
@Observable
final class TaskPipelineManager {
    enum Status {
        case idle
        case running
        case terminating
        case terminated
    }

    struct Failure {
        let functionName: String
        let terminationStatus: Int32
        let reason: String
    }

    enum PipelineError: Error, CustomStringConvertible {
        case executableNotFound(String)
        case startFailed(taskFunction: String, underlying: Error)

        var description: String {
            switch self {
            case .executableNotFound(let name): return "Executable '\(name)' not found in app bundle."
            case .startFailed(let fn, let err): return "Failed to start task '\(fn)': \(err)"
            }
        }
    }

    private static let monitorInterval: Duration = .seconds(5)
    private static let interStartDelay: TimeInterval = 0.2
    private static let postTerminateDelay: TimeInterval = 0.1

    private(set) var status: Status = .idle
    private(set) var lastFailure: Failure?
    private(set) var taskItems: [TaskItem] = []

    private var monitorTask: Task<Void, Never>?

    init() {}

    func makeTaskItem(executableName: String, functionName: String) throws -> TaskItem {
        guard let path = Bundle.main.path(forAuxiliaryExecutable: executableName) else {
            throw PipelineError.executableNotFound(executableName)
        }
        return TaskItem(path: path, functionName: functionName)
    }

    func makeTaskItem(pathToExecutable: String, functionName: String) -> TaskItem {
        return TaskItem(path: pathToExecutable, functionName: functionName)
    }

    /// Bundled SoX audio tool, embedded in Contents/Helpers alongside the other pipeline helpers.
    static var soxExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sox")
    }

    /// Resolves the bundled `sox` executable path, throwing if it is missing from the app bundle.
    func soxExecutablePath() throws -> String {
        let path = Self.soxExecutableURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw PipelineError.executableNotFound("sox")
        }
        return path
    }

    /// Creates a `TaskItem` for the bundled `sox` tool, ready to receive arguments and be added to the pipeline.
    func makeSoxTaskItem(functionName: String = "sox") throws -> TaskItem {
        return makeTaskItem(pathToExecutable: try soxExecutablePath(), functionName: functionName)
    }

    func add(_ taskItem: TaskItem) {
        taskItems.append(taskItem)
    }

    func start() throws {
        lastFailure = nil
        for item in taskItems {
            item.createTask()
        }
        configureTaskPipes()
        for item in taskItems {
            do {
                try item.start()
            } catch {
                for started in taskItems where started.process?.isRunning == true {
                    started.terminate()
                }
                status = .idle
                throw PipelineError.startFailed(taskFunction: item.functionName, underlying: error)
            }
            Thread.sleep(forTimeInterval: Self.interStartDelay)
        }
        status = .running
        startMonitor()
    }

    func terminate() {
        monitorTask?.cancel()
        monitorTask = nil
        status = .terminating
        for item in taskItems where item.process?.isRunning == true {
            item.terminate()
        }
        taskItems.removeAll()
        Thread.sleep(forTimeInterval: Self.postTerminateDelay)
        status = .terminated
    }

    func tasksInfoString() -> String {
        guard !taskItems.isEmpty else {
            return "No tasks currently running\n\n"
        }
        return taskItems.map { $0.taskInfoString() }.joined()
    }

    private func configureTaskPipes() {
        guard let first = taskItems.first else { return }
        first.process?.standardInput = FileHandle.nullDevice

        for (idx, item) in taskItems.enumerated() {
            if idx < taskItems.count - 1 {
                let pipe = Pipe()
                item.process?.standardOutput = pipe
                taskItems[idx + 1].process?.standardInput = pipe
            } else {
                item.process?.standardOutput = FileHandle.nullDevice
            }
            //item.process?.standardError = FileHandle.nullDevice
            item.process?.standardError = FileHandle.standardError   // TODO: disable after testing
        }
    }

    private func startMonitor() {
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.monitorInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                self.checkLiveness()
            }
        }
    }

    private func checkLiveness() {
        guard status == .running else { return }
        for item in taskItems {
            let running = item.process?.isRunning ?? false
            if !running {
                let exitStatus: Int32
                if let cached = item.lastTerminationStatus {
                    exitStatus = cached
                } else if let proc = item.process, !proc.isRunning, proc.processIdentifier != 0 {
                    exitStatus = proc.terminationStatus
                } else {
                    exitStatus = -1
                }
                print("TaskPipelineManager - failed task detected - \(item.functionName) exitStatus=\(exitStatus)")
                lastFailure = Failure(
                    functionName: item.functionName,
                    terminationStatus: exitStatus,
                    reason: "Task exited unexpectedly"
                )
                terminate()
                return
            }
        }
    }
}
