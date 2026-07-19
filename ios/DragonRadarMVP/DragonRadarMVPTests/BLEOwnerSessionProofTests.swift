import XCTest
@testable import DragonRadarMVP

final class BLEOwnerSessionProofTests: XCTestCase {
    func testOwnerSessionProofMatchesFirmwareContract() {
        let response = BLEOwnerSessionProof.make(
            challenge: "CR-A17C-00112233445566778899AABBCCDDEEFF",
            deviceToken: "ddt_owner_secret",
            nonce: "0123456789abcdef0123456789abcdef"
        )

        XCTAssertEqual(
            response,
            "dra-auth:v1:t:0123456789abcdef0123456789abcdef:678b9c7521851c309373db4fab73ce4e5fe6de0e14f04692664cc82abd5b7eee"
        )
    }

    func testOwnerSessionProofRejectsPlaceholderChallengeAndMissingToken() {
        XCTAssertNil(BLEOwnerSessionProof.make(challenge: "未读取", deviceToken: "ddt_owner_secret"))
        XCTAssertNil(BLEOwnerSessionProof.make(challenge: "CR-A17C-0011", deviceToken: ""))
        XCTAssertNil(
            BLEOwnerSessionProof.make(
                challenge: "CR-A17C-0011",
                deviceToken: "ddt_owner_secret",
                nonce: "too-short"
            )
        )
    }

    func testPairingTransactionRejectsStaleAlreadyPairedState() throws {
        let startedAt = Date()
        let status = try decodeStatus(
            last: "pairing_response locked",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertFalse(
            BLEPairingTransactionGate.pairingResponseAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
        XCTAssertTrue(
            BLEPairingTransactionGate.pairingResponseRejected(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt
            )
        )
    }

    func testPairingTransactionRequiresExactFreshConfirmation() throws {
        let startedAt = Date()
        let status = try decodeStatus(
            last: "pairing_response_verified",
            paired: 1,
            server: 0,
            ownerAuth: 1
        )

        XCTAssertFalse(
            BLEPairingTransactionGate.pairingResponseAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(-0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
        XCTAssertTrue(
            BLEPairingTransactionGate.pairingResponseAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
    }

    func testServerConfigRequiresFreshOwnerProof() throws {
        let startedAt = Date()
        let status = try decodeStatus(
            last: "owner_session_authorized",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertFalse(
            BLEPairingTransactionGate.serverConfigAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: false
            )
        )
        XCTAssertTrue(
            BLEPairingTransactionGate.serverConfigAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
    }

    private func decodeStatus(
        last: String,
        paired: Int,
        server: Int,
        ownerAuth: Int
    ) throws -> RadarBLEDeviceStatus {
        let json = """
        {
          "v": 2,
          "name": "CapsuleRadar-F2A0",
          "ble": 1,
          "paired": \(paired),
          "wifi": "connected",
          "rssi": -40,
          "ip": "192.0.2.1",
          "server": \(server),
          "loc": 0,
          "last": "\(last)",
          "owner_auth_required": 1,
          "owner_auth": \(ownerAuth)
        }
        """
        return try JSONDecoder().decode(RadarBLEDeviceStatus.self, from: Data(json.utf8))
    }
}
