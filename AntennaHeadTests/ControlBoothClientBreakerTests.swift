import XCTest
@testable import AntennaHead

/// The cool-down that keeps polling reads from freezing the app while
/// ControlBooth is running but not answering.
final class ControlBoothClientBreakerTests: XCTestCase {
    override func setUp() {
        ControlBoothClient.recordSuccess()
    }

    override func tearDown() {
        ControlBoothClient.recordSuccess()
    }

    func testPollingIsNotSkippedBeforeAnyTimeout() {
        XCTAssertFalse(ControlBoothClient.shouldSkipPolling())
    }

    func testPollingIsSkippedDuringTheCooldownThenResumes() {
        let timeout = Date(timeIntervalSince1970: 1_000_000)
        ControlBoothClient.recordTimeout(at: timeout)
        XCTAssertTrue(ControlBoothClient.shouldSkipPolling(now: timeout.addingTimeInterval(1)))
        XCTAssertTrue(ControlBoothClient.shouldSkipPolling(
            now: timeout.addingTimeInterval(ControlBoothClient.timeoutCooldown - 1)))
        XCTAssertFalse(ControlBoothClient.shouldSkipPolling(
            now: timeout.addingTimeInterval(ControlBoothClient.timeoutCooldown + 1)))
    }

    func testASuccessfulReplyEndsTheCooldown() {
        let timeout = Date()
        ControlBoothClient.recordTimeout(at: timeout)
        ControlBoothClient.recordSuccess()
        XCTAssertFalse(ControlBoothClient.shouldSkipPolling(now: timeout.addingTimeInterval(1)))
    }
}
