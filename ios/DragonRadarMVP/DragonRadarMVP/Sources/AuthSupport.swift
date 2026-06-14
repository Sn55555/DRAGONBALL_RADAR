import AuthenticationServices
import Foundation
import Security

struct AuthRepository {
    var httpBaseURL = AppEnvironment.current.httpAPIBaseURL

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws -> AuthSession {
        let fullName = credential.fullName
        let displayName = [fullName?.givenName, fullName?.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let identityToken = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return try await signInWithApple(
            appleUserID: credential.user,
            displayName: displayName.isEmpty ? "Dragon Radar User" : displayName,
            identityToken: identityToken
        )
    }

    func signInForDevelopment() async throws -> AuthSession {
        try await signInWithApple(
            appleUserID: "dev-local",
            displayName: "隼人",
            identityToken: "development"
        )
    }

    func refresh(_ session: AuthSession) async throws -> AuthSession {
        try await requestSession(path: "/v1/auth/refresh", payload: ["refresh_token": session.refreshToken])
    }

    private func signInWithApple(appleUserID: String, displayName: String, identityToken: String) async throws -> AuthSession {
        try await requestSession(
            path: "/v1/auth/apple",
            payload: [
                "apple_user_id": appleUserID,
                "display_name": displayName,
                "identity_token": identityToken
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
