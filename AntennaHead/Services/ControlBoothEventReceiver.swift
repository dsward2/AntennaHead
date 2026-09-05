import AppKit
import SharedLogging

/// AntennaHead's receiving half of the AppleEvents control channel with
/// ControlBooth (see "AppleEvents control channel" in ControlBooth's SETUP.md).
/// ControlBooth's `AntennaHeadClient` sends raw events of class 'AntH':
///
///   'Strt'  start listening task   direct parameter: source name (shown as the
///                                  station name while ControlBooth is the source)
///   'Stop'  stop listening task    direct parameter: source name
///   'Runs'  listening task names   reply: list of the listening tasks' names
///   'RecS'  start recording        direct parameter: filename to create.
///                                  Written into the shared App Group
///                                  container's Recordings folder (see
///                                  `SharedRecordingFolder`), which both apps
///                                  can reach without any bookmark relay.
///                                  optional 'Tone' parameter (boolean): when
///                                  true, gaps in real audio are filled with
///                                  an audible test tone instead of silence —
///                                  set by ControlBooth's manual test button
///                                  so a test recording is verifiable by ear
///                                  even with no station tuned.
///   'RecP'  stop recording         no parameters
///   'CBQt'  notify quitting        no parameters, no reply expected — sent
///                                  from ControlBooth's `applicationWillTerminate`.
///                                  Purely informational: `ControlBoothClient
///                                  .isControlBoothRunning`'s own
///                                  `NSRunningApplication` check is what
///                                  actually drives the ControlBooth Remote
///                                  Control web page's status, so this
///                                  handler only logs — it exists so
///                                  ControlBooth quitting is visible in
///                                  AntennaHead's log right away rather than
///                                  only inferable from the next poll.
///
/// AntennaHead runs at most one pipeline at a time, so 'Runs' replies with
/// zero or one name, and 'Stop' naming anything other than the active source
/// is a no-op. Receiving Apple events needs no sandbox entitlement (the
/// sender authorizes); errors are reported through the reply's errn/errs.
final class ControlBoothEventReceiver: NSObject {
    private let sdrController: SDRController
    private let lasManager: LiveAudioServerProcessManager

    @MainActor
    init(sdrController: SDRController, lasManager: LiveAudioServerProcessManager) {
        self.sdrController = sdrController
        self.lasManager = lasManager
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
        manager.setEventHandler(self,
                                andSelector: #selector(handleQuitting(_:withReplyEvent:)),
                                forEventClass: Self.eventClass,
                                andEventID: Self.fourCC("CBQt"))
        LogStore.shared.log(.info, source: "ControlBoothEventReceiver",
            "registered all 6 AE handlers (Strt/Stop/Runs/RecS/RecP/CBQt) — PID \(ProcessInfo.processInfo.processIdentifier)")
    }

    // NSAppleEventManager delivers on the main thread; the @objc entry points
    // are nonisolated only because selector dispatch can't carry actor isolation.

    @objc private func handleStartListening(_ event: NSAppleEventDescriptor,
                                            withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            guard let name = directParameter(of: event) else {
                setError(on: reply, code: Self.errAEWrongNumberArgs,
                         message: "'start listening' requires a source name.")
                return
            }
            // ControlBooth runs its own pipeline and sends PCM to AntennaHead
            // over UDP; this just switches AntennaHead's status/mode to show
            // ControlBooth as the active source. (Custom-task pipelines were
            // removed from AntennaHead — build them in ControlBooth instead.)
            // startControlBoothListening now waits for its receiver to report
            // ready before returning; this handler doesn't need that guarantee
            // itself (no reply value depends on it), so it's fire-and-forget
            // here rather than holding up the AE reply — same pattern as
            // handleStartRecording below.
            let controller = sdrController
            Task { @MainActor in await controller.startControlBoothListening(name: name) }
        }
    }

    @objc private func handleStopListening(_ event: NSAppleEventDescriptor,
                                           withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            guard let name = directParameter(of: event) else {
                setError(on: reply, code: Self.errAEWrongNumberArgs,
                         message: "'stop listening' requires a source name.")
                return
            }
            if sdrController.taskMode == .customTask, sdrController.stationName == name {
                sdrController.terminateTasks()
            }
        }
    }

    @objc private func handleListeningTasks(_ event: NSAppleEventDescriptor,
                                            withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            LogStore.shared.log(.info, source: "ControlBoothEventReceiver",
                "handleListeningTasks called — PID \(ProcessInfo.processInfo.processIdentifier)")
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
        MainActor.assumeIsolated {
            LogStore.shared.log(.info, source: "ControlBoothEventReceiver", "handleStartRecording called")
            guard let filename = directParameter(of: event) else {
                setError(on: reply, code: Self.errAEWrongNumberArgs,
                         message: "'start recording' requires a filename.")
                return
            }
            guard let directoryURL = SharedRecordingFolder.url else {
                setError(on: reply, code: Self.errAEEventFailed,
                         message: "AntennaHead's shared recording folder isn't available — check its App Group entitlement.")
                return
            }

            let fileURL = directoryURL.appendingPathComponent(filename)
            let useToneFiller = event.paramDescriptor(forKeyword: Self.keyUseToneFiller)?.booleanValue ?? false
            LogStore.shared.log(.info, source: "ControlBoothEventReceiver",
                "handleStartRecording — scheduling at \(fileURL.path), useToneFiller=\(useToneFiller)")
            let mgr = lasManager
            // A tone-filler test recording wants LiveAudioServer's own test
            // tone during dead air — but the auto filler feeds LAS real PCM,
            // so it would never emit the tone. Stop the filler for real
            // (handleStopRecording brings it back). A normal (silence-filler)
            // recording is left alone: capturing the beacon beats capturing
            // digital silence.
            let controller = sdrController
            if useToneFiller, controller.taskMode == .filler {
                controller.terminateTasks(enterIdle: false)
            }
            // Task { @MainActor } guarantees this runs after the handler
            // returns and the AE reply is dispatched, so terminate()'s Thread.sleep
            // elsewhere cannot block the reply. startRecording now calls LAS's
            // already-running instance over loopback HTTP (no process relaunch),
            // so this completes in milliseconds rather than racing a relaunch —
            // still fire-and-forget relative to the AE reply, but the window
            // for ControlBooth's Stop button to land before recording actually
            // started is now negligible. Only the recording-folder check above
            // is confirmed synchronously before this reply is sent.
            Task { @MainActor in await mgr.startRecording(at: fileURL, useToneFiller: useToneFiller) }
        }
    }

    @objc private func handleStopRecording(_ event: NSAppleEventDescriptor,
                                            withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            LogStore.shared.log(.info, source: "ControlBoothEventReceiver", "handleStopRecording called")
            let mgr = lasManager
            let controller = sdrController
            Task { @MainActor in
                await mgr.stopRecording()
                // Bring the filler back if a tone-filler recording had stopped
                // it and nothing else took over in the meantime.
                if controller.taskMode == .stopped, controller.fillerEnabled {
                    controller.startFillerPipeline()
                }
            }
        }
    }

    @objc private func handleQuitting(_ event: NSAppleEventDescriptor,
                                       withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            LogStore.shared.log(.info, source: "ControlBoothEventReceiver",
                "ControlBooth is quitting")
        }
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
    private static let typeNull = fourCC("null")
    private static let keyUseToneFiller = fourCC("Tone")

    private static let errAEWrongNumberArgs: Int32 = -1721
    private static let errAEEventFailed: Int32 = -10000
}
