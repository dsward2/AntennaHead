import AppKit

/// AntennaHead's sending half of the AppleEvents control channel with
/// ControlBooth (see "AppleEvents control channel" in ControlBooth's SETUP.md).
///
/// Targets ControlBooth's "ControlBooth Suite" — event class 'CBth':
///   'Strt'  start pipeline       direct parameter: pipeline name
///   'Stop'  stop pipeline        direct parameter: pipeline name
///   'StpA'  stop all pipelines
///   'List'  list pipelines       reply: list of text
///   'Runs'  running pipelines    reply: list of text
///
/// Every ControlBooth command is in the `com.dsward.ControlBooth.pipelines`
/// access group, matched by this app's `com.apple.security.scripting-targets`
/// entitlement, so sending from the sandbox works without an Automation
/// consent prompt. Sending waits synchronously for the reply (with a
/// timeout), so call from user-action contexts, not tight loops.
enum ControlBoothClient {
    static let bundleIdentifier = "com.dsward.ControlBooth"

    enum ClientError: Error, CustomStringConvertible {
        case notRunning
        case eventError(code: Int, message: String?)

        var description: String {
            switch self {
            case .notRunning:
                return "ControlBooth is not running."
            case .eventError(let code, let message):
                return message ?? "ControlBooth returned Apple Event error \(code)."
            }
        }
    }

    static var isControlBoothRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func startPipeline(named name: String) throws {
        _ = try send(eventID: "Strt", directParameter: NSAppleEventDescriptor(string: name))
    }

    static func stopPipeline(named name: String) throws {
        _ = try send(eventID: "Stop", directParameter: NSAppleEventDescriptor(string: name))
    }

    static func stopAllPipelines() throws {
        _ = try send(eventID: "StpA", directParameter: nil)
    }

    static func pipelines() throws -> [String] {
        try stringList(from: send(eventID: "List", directParameter: nil))
    }

    static func runningPipelines() throws -> [String] {
        try stringList(from: send(eventID: "Runs", directParameter: nil))
    }

    private static func stringList(from reply: NSAppleEventDescriptor) -> [String] {
        guard let list = reply.paramDescriptor(forKeyword: keyDirectObject),
              list.numberOfItems > 0 else {
            return []
        }
        // AEDesc list indices are 1-based.
        return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
    }

    private static func send(eventID: String, directParameter: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        guard isControlBoothRunning else {
            throw ClientError.notRunning
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC("CBth"),
            eventID: fourCC(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier),
            returnID: AEReturnID(-1),   // kAutoGenerateReturnID
            transactionID: AETransactionID(0)   // kAnyTransactionID
        )
        if let directParameter {
            event.setParam(directParameter, forKeyword: keyDirectObject)
        }
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 8)
        if let errorNumber = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
           errorNumber != 0 {
            throw ClientError.eventError(
                code: Int(errorNumber),
                message: reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue
            )
        }
        return reply
    }

    static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private static let keyDirectObject = fourCC("----")
    private static let keyErrorNumber = fourCC("errn")
    private static let keyErrorString = fourCC("errs")
}
