import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum AppleSignInNonce {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    static func make(length: Int = 32) throws -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "无法生成 Apple 登录安全随机数"]
            )
        }
        return String(randomBytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct AuthRepository {
    var httpBaseURL = AppEnvironment.current.httpAPIBaseURL

    func signInWithApple(
        credential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async throws -> AuthSession {
        let fullName = credential.fullName
        let displayName = [fullName?.givenName, fullName?.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let identityToken = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return try await signInWithApple(
            appleUserID: credential.user,
            displayName: displayName.isEmpty ? "Capsule Radar 用户" : displayName,
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce
        )
    }

    func signInForDevelopment() async throws -> AuthSession {
        try await signInWithApple(
            appleUserID: "dev-local",
            displayName: "隼人",
            identityToken: "development",
            authorizationCode: "",
            rawNonce: ""
        )
    }

    func refresh(_ session: AuthSession) async throws -> AuthSession {
        try await requestSession(path: "/v1/auth/refresh", payload: ["refresh_token": session.refreshToken])
    }

    func deleteAccount(accessToken: String) async throws -> AccountDeletionResult {
        guard let url = URL(string: httpBaseURL + "/v1/account") else {
            throw URLError(.badURL)
        }
        guard !accessToken.isEmpty else {
            throw RoomRepositoryError.server(code: "unauthorized", detail: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw RoomRepositoryError.server(code: error.code, detail: error.detail)
            }
            throw RoomRepositoryError.badResponse
        }
        let envelope = try JSONDecoder().decode(ServerAccountDeletionEnvelope.self, from: data)
        return AccountDeletionResult(
            appleAccessRevocationStatus: envelope.appleAccessRevocation.status,
            appleAccessRevocationReason: envelope.appleAccessRevocation.reason
        )
    }

    func signOut(accessToken: String) async throws {
        guard let url = URL(string: httpBaseURL + "/v1/auth/logout") else {
            throw URLError(.badURL)
        }
        guard !accessToken.isEmpty else {
            throw RoomRepositoryError.server(code: "unauthorized", detail: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw RoomRepositoryError.server(code: error.code, detail: error.detail)
            }
            throw RoomRepositoryError.badResponse
        }
    }

    private func signInWithApple(
        appleUserID: String,
        displayName: String,
        identityToken: String,
        authorizationCode: String,
        rawNonce: String
    ) async throws -> AuthSession {
        try await requestSession(
            path: "/v1/auth/apple",
            payload: [
                "apple_user_id": appleUserID,
                "display_name": displayName,
                "identity_token": identityToken,
                "authorization_code": authorizationCode,
                "nonce": rawNonce
            ]
        )
    }

    private func requestSession(path: String, payload: [String: String]) async throws -> AuthSession {
        guard let url = URL(string: httpBaseURL + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw RoomRepositoryError.server(code: error.code, detail: error.detail)
            }
            throw RoomRepositoryError.badResponse
        }
        let envelope = try JSONDecoder().decode(ServerAuthSessionEnvelope.self, from: data)
        return envelope.session.authSession
    }
}

struct AccountDeletionResult: Equatable {
    var appleAccessRevocationStatus: String
    var appleAccessRevocationReason: String?

    var requiresManualAppleRevocation: Bool {
        appleAccessRevocationStatus != "revoked"
    }
}

private struct ServerAccountDeletionEnvelope: Decodable {
    var appleAccessRevocation: ServerAppleAccessRevocation

    enum CodingKeys: String, CodingKey {
        case appleAccessRevocation = "apple_access_revocation"
    }
}

private struct ServerAppleAccessRevocation: Decodable {
    var status: String
    var reason: String?
}

private struct ServerAuthSessionEnvelope: Decodable {
    var session: ServerAuthSession
}

private struct ServerAuthSession: Decodable {
    var userID: String
    var displayName: String
    var appleUserID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case appleUserID = "apple_user_id"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    var authSession: AuthSession {
        AuthSession(
            userID: userID,
            displayName: displayName,
            appleUserID: appleUserID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt))
        )
    }
}

enum KeychainAuthStore {
    private static let service = "DragonRadar.auth.session"
    private static let account = "current"

    static func load() -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        delete()
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainPendingSessionRevocationStore {
    private static let service = "DragonRadar.auth.pending-revocation"
    private static let account = "access-token"

    static func load() -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return token
    }

    static func save(_ token: String) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, let data = cleanToken.data(using: .utf8) else {
            delete()
            return
        }
        delete()
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

#if !APP_ONLY
enum KeychainDeviceCredentialStore {
    private static let service = "DragonRadar.device.credential"
    private static let account = "active-device-token"

    static func load() -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return token
    }

    static func save(_ token: String) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, let data = cleanToken.data(using: .utf8) else {
            delete()
            return
        }
        delete()
        var item = baseQuery()
        item[kSecValueData as String] = data
        // The radar may reconnect while the phone is locked, so this credential
        // is available after first unlock but never migrates to another device.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
#endif
