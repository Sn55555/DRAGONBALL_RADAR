import XCTest
@testable import DragonRadarMVP

final class FirmwareReconnectPolicyTests: XCTestCase {
    func testTrackingIsLimitedToAnActiveDeviceOTATransaction() {
        let tracked: [FirmwareUpdatePhase] = [
            .sending, .canceling, .downloading, .verifying, .installing, .rebooting
        ]
        let untracked: [FirmwareUpdatePhase] = [
            .idle, .checking, .upToDate, .available, .succeeded, .failed,
            .bootstrapRequired, .rolledBack, .canceled
        ]

        XCTAssertTrue(tracked.allSatisfy(FirmwareReconnectPolicy.shouldTrack))
        XCTAssertTrue(untracked.allSatisfy { !FirmwareReconnectPolicy.shouldTrack($0) })
    }

    func testRetryPlanIsBoundedAndBacksOff() throws {
        let delays = try (1...FirmwareReconnectPolicy.maximumAttempts).map {
            try XCTUnwrap(FirmwareReconnectPolicy.delayBeforeAttempt($0))
        }

        XCTAssertEqual(delays.first, 0)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertNil(FirmwareReconnectPolicy.delayBeforeAttempt(0))
        XCTAssertNil(
            FirmwareReconnectPolicy.delayBeforeAttempt(FirmwareReconnectPolicy.maximumAttempts + 1)
        )
        XCTAssertTrue(
            FirmwareReconnectPolicy.hasBudget(
                attemptsStarted: FirmwareReconnectPolicy.maximumAttempts - 1,
                elapsed: FirmwareReconnectPolicy.reconnectWindow - 1
            )
        )
        XCTAssertFalse(
            FirmwareReconnectPolicy.hasBudget(
                attemptsStarted: FirmwareReconnectPolicy.maximumAttempts,
                elapsed: 0
            )
        )
        XCTAssertFalse(
            FirmwareReconnectPolicy.hasBudget(
                attemptsStarted: 0,
                elapsed: FirmwareReconnectPolicy.reconnectWindow
            )
        )
    }
}
