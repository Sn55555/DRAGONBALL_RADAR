import Foundation

struct FirmwareReconnectPolicy {
    static let maximumAttempts = 8
    static let attemptTimeout: TimeInterval = 6
    static let reconnectWindow: TimeInterval = 90

    private static let retryDelays: [TimeInterval] = [0, 1, 2, 3, 5, 7, 9, 11]

    static func shouldTrack(_ phase: FirmwareUpdatePhase) -> Bool {
        switch phase {
        case .sending, .canceling, .downloading, .verifying, .installing, .rebooting:
            true
        default:
            false
        }
    }

    static func delayBeforeAttempt(_ attemptNumber: Int) -> TimeInterval? {
        guard (1...maximumAttempts).contains(attemptNumber) else { return nil }
        return retryDelays[attemptNumber - 1]
    }

    static func hasBudget(attemptsStarted: Int, elapsed: TimeInterval) -> Bool {
        attemptsStarted < maximumAttempts && elapsed < reconnectWindow
    }
}
