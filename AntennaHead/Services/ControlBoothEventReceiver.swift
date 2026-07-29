import AppKit

/// AntennaHead's receiving half of the AppleEvents control channel with
/// ControlBooth (see "AppleEvents control channel" in ControlBooth's SETUP.md).
/// ControlBooth's `AntennaHeadClient` sends raw events of class 'AntH':
///
///   'Strt'  start listening task   direct parameter: custom-task name
///   'Stop'  stop listening task    direct parameter: custom-task name
///   'Runs'  listening task names   reply: list of the listening tasks' names
///   'RecS'  start recording        direct parameter: security-scoped bookmark
///                                  (Data) for the recording folder; 'fnam'
///                                  param: filename to create inside it.
///                                  AntennaHead is sandboxed and has no access
///                                  to a folder ControlBooth picked without
///                                  this bookmark — see `handleStartRecording`.
///   'RecP'  stop recording         no parameters
///
/// AntennaHead runs at most one pipeline at a time, so 'Runs' replies with
/// zero or one name, and 'Stop' naming anything other than the active custom
/// task is a no-op. Receiving Apple events needs no sandbox entitlement (the
/// sender authorizes); errors are reported through the reply's errn/errs.
final class ControlBoothEventReceiver: NSObject {
    private let sdrController: SDRController
    private let lasManager: LiveAudioServerProcessManager
    private let sqlite: SQLiteController

    /// The recording folder's security-scoped resource access, held open for
    /// as long as a recording started via 'RecS' is in progress. Released by
    /// 'RecP' (or by the next 'RecS', if one arrives without a matching stop).
    private var activeRecordingScopedURL: URL?

    @MainActor
    init(sdrController: SDRController, lasManager: LiveAudioServerProcessManager,
         sqlite: SQLiteController = .shared) {
        self.sdrController = sdrController
        self.lasManager = lasManager
        self.sqlite = sqlite
        super.init()

        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(self,
                                andSelector: #selector(handleStartListening(_:withReplyEvent:)),
                                forEventClass: Self.eventClass,
                                andEventID: Self.fourCC("Strt"))
        manager.setEventHandler(self,
                                andSelector: #selector(handleStopListening(_:withReplyEvent:)),
                                forEventClass: Self.eventClass,
                                andEventID: Self.fourCC("Stop"))
        manager.setEventHandler(self,
                                andSelector: #selector(handleListeningTasks(_:withReplyEvent:)),
                                forEventClass: Self.eventClass,
                                andEventID: Self.fourCC("Runs"))
        manager.setEventHandler(self,
                                andSelector: #selector(handleStartRecording(_:withReplyEvent:)),
                                forEventClass: Self.eventClass,
                                andEventID: Self.fourCC("RecS"))
        manager.setEventHandler(self,
                                andSelector: #selector(handleStopRecording(_:withReplyEvent:)),
                                forEventClass: Self.eventClass,
                                andEventID: Self.fourCC("RecP"))
        print("ControlBoothEventReceiver: registered all 5 AE handlers (Strt/Stop/Runs/RecS/RecP) — PID \(ProcessInfo.processInfo.processIdentifier)")
    }

    // NSAppleEventManager delivers on the main thread; the @objc entry points
    // are nonisolated only because selector dispatch can't carry actor isolation.

    @objc private func handleStartListening(_ event: NSAppleEventDescriptor,
                                            withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            guard let name = directParameter(of: event) else {
                setError(on: reply, code: Self.errAEWrongNumberArgs,
                         message: "'start listening' requires a custom-task name.")
                return
            }
            if let id = customTaskID(named: name) {
                do {
                    try sdrController.startTasksForCustomTask(id: id)
                    // startTasksForCustomTask reports pipeline launch failures via
                    // lastError instead of throwing.
                    if let error = sdrController.lastError {
                        setError(on: reply, code: Self.errAEEventFailed, message: "\(error)")
                    }
                } catch {
                    setError(on: reply, code: Self.errAEEventFailed, message: "\(error)")
                }
            } else {
                // No local custom task with this name: ControlBooth sends PCM
                // directly to LAS, so just update AntennaHead's status/mode.
                sdrController.startControlBoothListening(name: name)
            }
        }
    }

    @objc private func handleStopListening(_ event: NSAppleEventDescriptor,
                                           withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            guard let name = directParameter(of: event) else {
                setError(on: reply, code: Self.errAEWrongNumberArgs,
                         message: "'stop listening' requires a custom-task name.")
                return
            }
            if sdrController.taskMode == .customTask, sdrController.stationName == name {
                sdrController.terminateTasks()
            }
        }
    }

    @objc private func handleListeningTasks(_ event: NSAppleEventDescriptor,
                                            withReplyEvent reply: NSAppleEventDescriptor) {
        print("ControlBoothEventReceiver: handleListeningTasks called — PID \(ProcessInfo.processInfo.processIdentifier)")
        MainActor.assumeIsolated {
            let list = NSAppleEventDescriptor.list()
            if sdrController.taskMode == .customTask, !sdrController.stationName.isEmpty {
                list.insert(NSAppleEventDescriptor(string: sdrController.stationName), at: 1)
            }
            if reply.descriptorType != Self.typeNull {
                reply.setParam(list, forKeyword: Self.keyDirectObject)
            }
        }
    }

    @objc private func handleStartRecording(_ event: NSAppleEventDescriptor,
                                             withReplyEvent reply: NSAppleEventDescriptor) {
        print("ControlBoothEventReceiver: handleStartRecording called")
        MainActor.assumeIsolated {
            guard let bookmark = event.paramDescriptor(forKeyword: Self.keyDirectObject)?.data,
                  !bookmark.isEmpty else {
                setError(on: reply, code: Self.errAEWrongNumberArgs,
                         message: "'start recording' requires a security-scoped bookmark for the recording folder.")
                return
            }
            guard let filename = event.paramDescriptor(forKeyword: Self.keyRecordingFilename)?.stringValue,
                  !filename.isEmpty else {
                setError(on: reply, code: Self.errAEWrongNumberArgs,
                         message: "'start recording' requires a filename.")
                return
            }

            // Resolving the bookmark and gaining access are both synchronous
            // and fast (no subprocess involved), so it's safe to check them
            // here and reply with a real error immediately — unlike the
            // subprocess relaunch below, which stays fire-and-forget.
            var isStale = false
            let directoryURL: URL
            do {
                directoryURL = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                        relativeTo: nil, bookmarkDataIsStale: &isStale)
            } catch {
                print("ControlBoothEventReceiver: handleStartRecording — bookmark resolution failed: \(error)")
                setError(on: reply, code: Self.errAEEventFailed,
                         message: "Couldn't resolve the recording folder's bookmark: \(error). Re-pick the folder in ControlBooth's schedule editor.")
                return
            }
            if isStale {
                print("ControlBoothEventReceiver: handleStartRecording — bookmark is stale, using it anyway; ask ControlBooth to re-pick the folder soon")
            }
            guard directoryURL.startAccessingSecurityScopedResource() else {
                setError(on: reply, code: Self.errAEEventFailed,
                         message: "Sandbox denied access to the recording folder (\(directoryURL.path)). Re-pick it in ControlBooth's schedule editor.")
                return
            }

            // A previous recording's access wasn't released (e.g. a 'RecS'
            // arrived without a matching 'RecP') — release it before this one
            // takes over, rather than leaking the security-scoped grant.
            if let previous = activeRecordingScopedURL {
                previous.stopAccessingSecurityScopedResource()
            }
            activeRecordingScopedURL = directoryURL

            let fileURL = directoryURL.appendingPathComponent(filename)
            print("ControlBoothEventReceiver: handleStartRecording — scheduling at \(fileURL.path)")
            let mgr = lasManager
            // DispatchQueue.main.async guarantees work runs after this handler
            // returns and the AE reply is dispatched, so terminate()'s Thread.sleep
            // cannot block the reply. Whether the LiveAudioServer relaunch itself
            // succeeds remains fire-and-forget — only the sandbox-access check
            // above is confirmed synchronously before this reply is sent.
            DispatchQueue.main.async { mgr.startRecording(at: fileURL) }
        }
    }

    @objc private func handleStopRecording(_ event: NSAppleEventDescriptor,
                                            withReplyEvent reply: NSAppleEventDescriptor) {
        print("ControlBoothEventReceiver: handleStopRecording called")
        MainActor.assumeIsolated {
            let mgr = lasManager
            DispatchQueue.main.async { mgr.stopRecording() }
            activeRecordingScopedURL?.stopAccessingSecurityScopedResource()
            activeRecordingScopedURL = nil
        }
    }

    @MainActor
    private func customTaskID(named name: String) -> Int64? {
        let tasks = (try? sqlite.allCustomTaskRecords()) ?? []
        return tasks.first { $0.taskName == name }?.id
    }

    private func directParameter(of event: NSAppleEventDescriptor) -> String? {
        guard let name = event.paramDescriptor(forKeyword: Self.keyDirectObject)?.stringValue,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Records an error on the reply so the sender's `sendEvent` surfaces it.
    /// A sender that didn't wait for a reply passes a null descriptor, which
    /// silently ignores parameters.
    private func setError(on reply: NSAppleEventDescriptor, code: Int32, message: String) {
        guard reply.descriptorType != Self.typeNull else { return }
        reply.setParam(NSAppleEventDescriptor(int32: code), forKeyword: Self.keyErrorNumber)
        reply.setParam(NSAppleEventDescriptor(string: message), forKeyword: Self.keyErrorString)
    }

    static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private static let eventClass = fourCC("AntH")
    private static let keyDirectObject = fourCC("----")
    private static let keyErrorNumber = fourCC("errn")
    private static let keyErrorString = fourCC("errs")
    private static let keyRecordingFilename = fourCC("fnam")
    private static let typeNull = fourCC("null")

    private static let errAEWrongNumberArgs: Int32 = -1721
    private static let errAENoSuchObject: Int32 = -1728
    private static let errAEEventFailed: Int32 = -10000
}
