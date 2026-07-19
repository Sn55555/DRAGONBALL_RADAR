import Foundation
import Observation

enum ModerationContentType: String, CaseIterable, Identifiable, Codable {
    case profileName = "profile_name"
    case roomName = "room_name"
    #if !APP_ONLY
    case voice
    #endif
    case behavior
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profileName: "成员资料"
        case .roomName: "房间名称"
        #if !APP_ONLY
        case .voice: "语音互动"
        #endif
        case .behavior: "成员行为"
        case .other: "其他内容"
        }
    }
}

enum ModerationReportCategory: String, CaseIterable, Identifiable, Codable {
    case harassment
    case hateSpeech = "hate_speech"
    case sexualContent = "sexual_content"
    case violence
    case spam
    case impersonation
    case privacy
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .harassment: "骚扰或欺凌"
        case .hateSpeech: "仇恨言论"
        case .sexualContent: "色情或不当内容"
        case .violence: "暴力或威胁"
        case .spam: "垃圾信息"
        case .impersonation: "冒充他人"
        case .privacy: "隐私侵害"
        case .other: "其他问题"
        }
    }
}

struct ModerationReportReceipt: Decodable, Hashable {
    var caseNumber: String
    var status: String
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case caseNumber = "case_number"
        case status
        case createdAt = "created_at"
    }
}

struct ModerationReportEnvelope: Decodable {
    var report: ModerationReportReceipt
}

struct UserBlockRecord: Identifiable, Decodable, Hashable {
    var id: String { blockID }

    var blockID: String
    var roomCode: String
    var moderationRef: String
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case roomCode = "room_code"
        case moderationRef = "moderation_ref"
        case createdAt = "created_at"
    }
}

struct UserBlocksEnvelope: Decodable {
    var blocks: [UserBlockRecord]
}

struct UserBlockEffect: Decodable, Hashable {
    enum Action: String {
        case blockedUserRemoved = "blocked_user_removed"
        case blockerLeft = "blocker_left"
        case unknown
    }

    var roomCode: String
    var actionValue: String
    var disconnectedConnections: Int

    var action: Action { Action(rawValue: actionValue) ?? .unknown }

    enum CodingKeys: String, CodingKey {
        case roomCode = "room_code"
        case actionValue = "action"
        case disconnectedConnections = "disconnected_connections"
    }

    init(roomCode: String, action: Action, disconnectedConnections: Int) {
        self.roomCode = roomCode
        actionValue = action.rawValue
        self.disconnectedConnections = disconnectedConnections
    }
}

struct UserBlockEnvelope: Decodable {
    var block: UserBlockRecord
    var effects: [UserBlockEffect]
}

struct UserUnblockEnvelope: Decodable {
    var ok: Bool
    var block: UserBlockRecord
}

struct ModerationReportOperationResult {
    var succeeded: Bool
    var message: String
    var caseNumber: String?
}

struct ModerationBlockOperationResult {
    var succeeded: Bool
    var message: String
    var leftCurrentRoom: Bool
}

@MainActor
@Observable
final class ModerationRepository {
    var httpBaseURL = AppEnvironment.current.httpAPIBaseURL
    var accessToken = ""
    @ObservationIgnored private var urlSession: URLSession

    #if DEBUG
    var uiTestingEnabled = false
    private var uiTestingBlocks: [UserBlockRecord] = []
    #endif

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    var usesInMemoryTestingStore: Bool {
        #if DEBUG
        uiTestingEnabled
        #else
        false
        #endif
    }

    func submitReport(
        roomCode: String,
        moderationRef: String,
        contentType: ModerationContentType,
        category: ModerationReportCategory,
        details: String
    ) async throws -> ModerationReportReceipt {
        guard details.count <= 1_000 else {
            throw RoomRepositoryError.server(code: "report_details_too_long", detail: nil)
        }
        #if DEBUG
        if uiTestingEnabled {
            return ModerationReportReceipt(
                caseNumber: "DR-UI-0001",
                status: "received",
                createdAt: Int(Date().timeIntervalSince1970)
            )
        }
        #endif
        let data = try await request(
            path: "/v1/reports",
            method: "POST",
            payload: [
                "room_code": roomCode,
                "moderation_ref": moderationRef,
                "content_type": contentType.rawValue,
                "category": category.rawValue,
                "details": details
            ]
        )
        return try JSONDecoder().decode(ModerationReportEnvelope.self, from: data).report
    }

    func listBlocks() async throws -> [UserBlockRecord] {
        #if DEBUG
        if uiTestingEnabled {
            return uiTestingBlocks
        }
        #endif
        let data = try await request(path: "/v1/blocks", method: "GET")
        return try JSONDecoder().decode(UserBlocksEnvelope.self, from: data).blocks
    }

    func block(roomCode: String, moderationRef: String) async throws -> UserBlockEnvelope {
        #if DEBUG
        if uiTestingEnabled {
            let block = UserBlockRecord(
                blockID: "blk_ui_0001",
                roomCode: roomCode,
                moderationRef: moderationRef,
                createdAt: Int(Date().timeIntervalSince1970)
            )
            uiTestingBlocks.removeAll { $0.moderationRef == moderationRef }
            uiTestingBlocks.insert(block, at: 0)
            return UserBlockEnvelope(
                block: block,
                effects: [
                    UserBlockEffect(
                        roomCode: roomCode,
                        action: .blockedUserRemoved,
                        disconnectedConnections: 1
                    )
                ]
            )
        }
        #endif
        let data = try await request(
            path: "/v1/blocks",
            method: "POST",
            payload: [
                "room_code": roomCode,
                "moderation_ref": moderationRef
            ]
        )
        return try JSONDecoder().decode(UserBlockEnvelope.self, from: data)
    }

    func unblock(blockID: String) async throws -> UserBlockRecord {
        #if DEBUG
        if uiTestingEnabled {
            guard let index = uiTestingBlocks.firstIndex(where: { $0.blockID == blockID }) else {
                throw RoomRepositoryError.server(code: "block_not_found", detail: nil)
            }
            return uiTestingBlocks.remove(at: index)
        }
        #endif
        let safeBlockID = blockID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? blockID
        let data = try await request(path: "/v1/blocks/\(safeBlockID)", method: "DELETE")
        return try JSONDecoder().decode(UserUnblockEnvelope.self, from: data).block
    }

    #if DEBUG
    func seedUITestingBlock(roomCode: String, moderationRef: String) {
        uiTestingBlocks = [
            UserBlockRecord(
                blockID: "blk_ui_seeded",
                roomCode: roomCode,
                moderationRef: moderationRef,
                createdAt: Int(Date().timeIntervalSince1970) - 60
            )
        ]
    }
    #endif

    private func request(
        path: String,
        method: String,
        payload: [String: String]? = nil
    ) async throws -> Data {
        guard let url = URL(string: httpBaseURL + path) else {
            throw URLError(.badURL)
        }
        guard !accessToken.isEmpty else {
            throw RoomRepositoryError.server(code: "unauthorized", detail: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RoomRepositoryError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                if http.statusCode == 429 {
                    let headerRetryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                    throw RoomRepositoryError.rateLimited(
                        code: error.code,
                        detail: error.detail,
                        retryAfter: error.retryAfter ?? headerRetryAfter ?? 1
                    )
                }
                throw RoomRepositoryError.server(code: error.code, detail: error.detail)
            }
            throw RoomRepositoryError.badResponse
        }
        return data
    }
}
