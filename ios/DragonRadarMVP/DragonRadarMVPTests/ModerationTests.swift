import Foundation
import XCTest
@testable import DragonRadarMVP

final class ModerationTests: XCTestCase {
    @MainActor
    func testRoomStateModerationRefOnlyEnablesRemoteAppMember() throws {
        let localRef = "mod_v1_" + String(repeating: "A", count: 43)
        let remoteRef = "mod_v1_" + String(repeating: "B", count: 43)
        let json = """
        {
          "room": "CAPS-SAFE",
          "server_time": 1784000000,
          "max_members": 7,
          "members": [
            {
              "role": "app", "member_id": "local", "peer_id": "local-app",
              "name": "Local", "online": true, "age_ms": 0,
              "last_seen_ms": 1, "last_type": "room_state",
              "moderation_ref": "\(localRef)"
            },
            {
              "role": "app", "member_id": "same-account", "peer_id": "same-account-app",
              "name": "Same Account", "online": true, "age_ms": 0,
              "last_seen_ms": 2, "last_type": "room_state",
              "moderation_ref": "\(localRef)"
            },
            {
              "role": "app", "member_id": "remote", "peer_id": "remote-app",
              "name": "Remote", "online": true, "age_ms": 0,
              "last_seen_ms": 3, "last_type": "room_state",
              "moderation_ref": "\(remoteRef)"
            },
            {
              "role": "device", "member_id": "device", "peer_id": "device-peer",
              "name": "Radar", "online": true, "age_ms": 0,
              "last_seen_ms": 4, "last_type": "device_status"
            }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(RelayRoomStateSnapshot.self, from: json)
        XCTAssertEqual(snapshot.members[2].moderationRef, remoteRef)

        let store = RoomsStore(resetPersistentState: true)
        store.applyRelayRoomState(snapshot, localAppPeerID: "local-app")

        XCTAssertTrue(store.members[0].isLocal)
        XCTAssertFalse(store.members[0].canUseModerationActions, "Self must never expose report/block actions.")
        XCTAssertFalse(store.members[1].isLocal)
        XCTAssertTrue(store.members[1].isCurrentUser)
        XCTAssertFalse(
            store.members[1].canUseModerationActions,
            "Another app group owned by the signed-in user must still be treated as self."
        )
        XCTAssertEqual(store.members[2].moderationRef, remoteRef)
        XCTAssertTrue(store.members[2].canUseModerationActions)
        XCTAssertEqual(store.members[3].role, "device")
        XCTAssertFalse(store.members[3].canUseModerationActions, "Device-only slots are not user moderation targets.")
    }

    func testReportAndBlockResponsesDecodeExistingServerSchema() throws {
        let reportJSON = #"""
        {
          "report": {
            "case_number": "DR-20260715-1A2B3C4D",
            "status": "received",
            "created_at": 1784000000
          }
        }
        """#.data(using: .utf8)!
        let report = try JSONDecoder().decode(ModerationReportEnvelope.self, from: reportJSON).report
        XCTAssertEqual(report.caseNumber, "DR-20260715-1A2B3C4D")
        XCTAssertEqual(report.status, "received")

        let blockJSON = #"""
        {
          "block": {
            "block_id": "blk_123",
            "room_code": "CAPS-SAFE",
            "moderation_ref": "mod_v1_remote",
            "created_at": 1784000000
          },
          "effects": [
            {
              "room_code": "CAPS-SAFE",
              "action": "blocker_left",
              "disconnected_connections": 1
            },
            {
              "room_code": "CAPS-OWNED",
              "action": "blocked_user_removed",
              "disconnected_connections": 2
            }
          ]
        }
        """#.data(using: .utf8)!
        let block = try JSONDecoder().decode(UserBlockEnvelope.self, from: blockJSON)
        XCTAssertEqual(block.block.blockID, "blk_123")
        XCTAssertEqual(block.effects[0].action, .blockerLeft)
        XCTAssertEqual(block.effects[1].action, .blockedUserRemoved)
        XCTAssertEqual(block.effects[1].disconnectedConnections, 2)
    }

    @MainActor
    func testReportRequestUsesOpaqueModerationRefAndExistingPayloadKeys() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModerationMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let repository = ModerationRepository(urlSession: session)
        repository.httpBaseURL = "https://example.test"
        repository.accessToken = "access-token"

        let moderationRef = "mod_v1_" + String(repeating: "Z", count: 43)
        ModerationMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/reports")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(
                Set(payload.keys),
                Set(["room_code", "moderation_ref", "content_type", "category", "details"])
            )
            XCTAssertEqual(payload["room_code"], "CAPS-SAFE")
            XCTAssertEqual(payload["moderation_ref"], moderationRef)
            XCTAssertEqual(payload["content_type"], "behavior")
            XCTAssertEqual(payload["category"], "privacy")
            XCTAssertNil(payload["apple_user_id"])

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let data = #"{"report":{"case_number":"DR-20260715-ABCDEF12","status":"received","created_at":1784000000}}"#
                .data(using: .utf8)!
            return (response, data)
        }

        let receipt = try await repository.submitReport(
            roomCode: "CAPS-SAFE",
            moderationRef: moderationRef,
            contentType: .behavior,
            category: .privacy,
            details: "位置被擅自公开"
        )

        XCTAssertEqual(receipt.caseNumber, "DR-20260715-ABCDEF12")
    }

    @MainActor
    func testBlockListCreateAndDeleteUseExistingServerRoutes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModerationMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let repository = ModerationRepository(urlSession: session)
        repository.httpBaseURL = "https://example.test"
        repository.accessToken = "access-token"

        let moderationRef = "mod_v1_" + String(repeating: "Q", count: 43)
        let blockJSON = #"{"block_id":"blk_123","room_code":"CAPS-SAFE","moderation_ref":"mod_v1_QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ","created_at":1784000000}"#

        ModerationMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: request.httpMethod == "POST" ? 201 : 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )

            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/blocks"):
                XCTAssertNil(request.httpBody)
                return (response, (#"{"blocks":["# + blockJSON + #"]}"#).data(using: .utf8)!)

            case ("POST", "/v1/blocks"):
                let body = try XCTUnwrap(Self.bodyData(from: request))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(Set(payload.keys), Set(["room_code", "moderation_ref"]))
                XCTAssertEqual(payload["room_code"], "CAPS-SAFE")
                XCTAssertEqual(payload["moderation_ref"], moderationRef)
                XCTAssertNil(payload["apple_user_id"])
                return (response, (#"{"block":"# + blockJSON + #", "effects":[]}"#).data(using: .utf8)!)

            case ("DELETE", "/v1/blocks/blk_123"):
                XCTAssertNil(request.httpBody)
                return (response, (#"{"ok":true,"block":"# + blockJSON + #"}"#).data(using: .utf8)!)

            default:
                XCTFail("Unexpected moderation request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }

        let listed = try await repository.listBlocks()
        XCTAssertEqual(listed.map(\.blockID), ["blk_123"])

        let created = try await repository.block(roomCode: "CAPS-SAFE", moderationRef: moderationRef)
        XCTAssertEqual(created.block.blockID, "blk_123")

        let removed = try await repository.unblock(blockID: "blk_123")
        XCTAssertEqual(removed.blockID, "blk_123")
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    @MainActor
    func testReportDetailsOverOneThousandCharactersAreRejectedLocally() async {
        let repository = ModerationRepository()
        repository.accessToken = "access-token"

        do {
            _ = try await repository.submitReport(
                roomCode: "CAPS-SAFE",
                moderationRef: "mod_v1_" + String(repeating: "Z", count: 43),
                contentType: .other,
                category: .other,
                details: String(repeating: "字", count: 1_001)
            )
            XCTFail("Expected the 1000-character contract to be enforced before networking.")
        } catch let error as RoomRepositoryError {
            XCTAssertEqual(error.errorDescription, "补充说明不能超过 1000 字。")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class ModerationMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
