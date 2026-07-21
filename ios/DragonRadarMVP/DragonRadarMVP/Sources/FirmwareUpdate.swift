import CryptoKit
import Foundation
import Observation

struct FirmwareSemanticVersion: Hashable, Comparable, CustomStringConvertible {
    let rawValue: String
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ rawValue: String) {
        let pattern = #"^[0-9]+\.[0-9]+\.[0-9]+$"#
        guard rawValue.range(of: pattern, options: .regularExpression) != nil else { return nil }

        let core = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard
            core.count == 3,
            let major = Int(core[0]),
            let minor = Int(core[1]),
            let patch = Int(core[2]),
            major <= Int(UInt32.max),
            minor <= Int(UInt32.max),
            patch <= Int(UInt32.max)
        else { return nil }

        self.rawValue = rawValue
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = []
    }

    var description: String { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }

        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber < rightNumber
            }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct FirmwareManifest: Codable, Hashable {
    var schema: Int
    var product: String
    var hardware: String
    var version: String
    var build: Int
    var minimumVersion: String
    var securityCounter: Int
    var size: Int
    var sha256: String
    var signatureAlgorithm: String
    var keyID: String
    var signature: String
    var artifactURL: String
    var channel: String?
    var releaseNotes: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case product
        case hardware
        case version
        case build
        case minimumVersion = "minimum_version"
        case securityCounter = "security_counter"
        case size
        case sha256
        case signatureAlgorithm = "signature_algorithm"
        case keyID = "key_id"
        case signature
        case artifactURL = "artifact_url"
        case channel
        case releaseNotes = "release_notes"
    }

    var canonicalString: String {
        [
            "dragon-radar-ota-v1",
            "schema=\(schema)",
            "product=\(product)",
            "hardware=\(hardware)",
            "version=\(version)",
            "build=\(build)",
            "minimum_version=\(minimumVersion)",
            "security_counter=\(securityCounter)",
            "size=\(size)",
            "sha256=\(sha256)"
        ].joined(separator: "\n")
    }

    var canonicalData: Data { Data(canonicalString.utf8) }
    var semanticVersion: FirmwareSemanticVersion? { FirmwareSemanticVersion(version) }
    var minimumSemanticVersion: FirmwareSemanticVersion? { FirmwareSemanticVersion(minimumVersion) }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    func compactControlData(artifactURL absoluteArtifactURL: URL) throws -> Data {
        let envelope = FirmwareControlEnvelope(
            v: 1,
            a: "start",
            m: .init(
                s: schema,
                p: product,
                h: hardware,
                v: version,
                b: build,
                min: minimumVersion,
                c: securityCounter,
                z: size,
                sha: sha256,
                alg: signatureAlgorithm,
                kid: keyID,
                sig: signature,
                url: absoluteArtifactURL.absoluteString
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }
}

private struct FirmwareControlEnvelope: Encodable {
    struct CompactManifest: Encodable {
        var s: Int
        var p: String
        var h: String
        var v: String
        var b: Int
        var min: String
        var c: Int
        var z: Int
        var sha: String
        var alg: String
        var kid: String
        var sig: String
        var url: String
    }

    var v: Int
    var a: String
    var m: CompactManifest
}

enum FirmwareManifestError: LocalizedError, Equatable {
    case invalidField(String)
    case unsupportedAlgorithm
    case unsupportedKey
    case invalidSignatureEncoding
    case invalidSignature
    case invalidArtifactURL
    case crossOriginArtifact
    case unauthorized
    case server(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case let .invalidField(field): "固件清单字段无效：\(field)"
        case .unsupportedAlgorithm: "固件签名算法不受支持"
        case .unsupportedKey: "固件签名密钥不受信任"
        case .invalidSignatureEncoding: "固件签名格式无效"
        case .invalidSignature: "固件签名验证失败，更新已阻止"
        case .invalidArtifactURL: "固件下载地址无效"
        case .crossOriginArtifact: "固件下载地址不是可信同源地址"
        case .unauthorized: "登录状态已失效，请重新登录"
        case let .server(code): "固件服务暂不可用：\(code)"
        case .badResponse: "固件服务返回异常"
        }
    }
}

struct FirmwareManifestVerifier {
    static let expectedProduct = "dragon-radar"
    static let expectedHardware = "esp32-s3-touch-amoled-1.75c"
    static let expectedAlgorithm = "ecdsa-p256-sha256"
    static let expectedKeyID = "local-2026-01"

    static let embeddedPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAERJP6AojGHRBbMmkTNPVSzRM8PJ+l
    grKYl5uvOHIfnnjZE9rWSVZnlAAA4hD2YLqP5W59WvowPnX7CueQRMNOCA==
    -----END PUBLIC KEY-----
    """

    var publicKeyPEM = Self.embeddedPublicKeyPEM

    func verify(_ manifest: FirmwareManifest) throws {
        guard manifest.schema == 1 else { throw FirmwareManifestError.invalidField("schema") }
        guard manifest.product == Self.expectedProduct else { throw FirmwareManifestError.invalidField("product") }
        guard manifest.hardware == Self.expectedHardware else { throw FirmwareManifestError.invalidField("hardware") }
        guard let version = manifest.semanticVersion else { throw FirmwareManifestError.invalidField("version") }
        guard let minimumVersion = manifest.minimumSemanticVersion else {
            throw FirmwareManifestError.invalidField("minimum_version")
        }
        guard version >= minimumVersion else {
            throw FirmwareManifestError.invalidField("version_minimum_order")
        }
        guard manifest.build > 0, manifest.build <= Int(UInt32.max) else {
            throw FirmwareManifestError.invalidField("build")
        }
        guard manifest.securityCounter >= 1, manifest.securityCounter <= Int(UInt32.max) else {
            throw FirmwareManifestError.invalidField("security_counter")
        }
        guard manifest.size > 0 else { throw FirmwareManifestError.invalidField("size") }
        guard manifest.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw FirmwareManifestError.invalidField("sha256")
        }
        for value in [manifest.product, manifest.hardware, manifest.version, manifest.minimumVersion, manifest.sha256] {
            guard !value.contains("\n"), !value.contains("\r"), !value.contains("=") else {
                throw FirmwareManifestError.invalidField("canonical_value")
            }
        }
        guard manifest.signatureAlgorithm == Self.expectedAlgorithm else {
            throw FirmwareManifestError.unsupportedAlgorithm
        }
        guard manifest.keyID == Self.expectedKeyID else { throw FirmwareManifestError.unsupportedKey }
        guard let signatureData = Data(base64Encoded: manifest.signature) else {
            throw FirmwareManifestError.invalidSignatureEncoding
        }

        do {
            let publicKey = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            guard publicKey.isValidSignature(signature, for: manifest.canonicalData) else {
                throw FirmwareManifestError.invalidSignature
            }
        } catch let error as FirmwareManifestError {
            throw error
        } catch {
            throw FirmwareManifestError.invalidSignatureEncoding
        }
    }
}

struct VerifiedFirmwareManifest: Hashable {
    var manifest: FirmwareManifest
    var artifactURL: URL
}

enum FirmwareArtifactURLPolicy {
    static func resolve(_ value: String, baseURLString: String, requireHTTPS: Bool) throws -> URL {
        guard
            let baseURL = URL(string: baseURLString),
            let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL
        else { throw FirmwareManifestError.invalidArtifactURL }
        try validate(resolved, baseURLString: baseURLString, requireHTTPS: requireHTTPS)
        return resolved
    }

    static func validate(_ url: URL, baseURLString: String, requireHTTPS: Bool) throws {
        guard let baseURL = URL(string: baseURLString) else { throw FirmwareManifestError.invalidArtifactURL }
        guard
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
            url.host?.lowercased() == baseURL.host?.lowercased(),
            url.port == baseURL.port,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else { throw FirmwareManifestError.crossOriginArtifact }
        if requireHTTPS, url.scheme?.lowercased() != "https" {
            throw FirmwareManifestError.invalidArtifactURL
        }

        let prefix = "/v1/firmware/artifacts/"
        guard url.path.hasPrefix(prefix) else { throw FirmwareManifestError.invalidArtifactURL }
        let basename = String(url.path.dropFirst(prefix.count))
        guard
            !basename.contains("/"),
            basename.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$"#, options: .regularExpression) != nil
        else { throw FirmwareManifestError.invalidArtifactURL }
    }
}

struct FirmwareManifestRepository {
    var baseURLString = AppEnvironment.current.httpAPIBaseURL
    var session = URLSession.shared
    var verifier = FirmwareManifestVerifier()

    func fetch(accessToken: String, channel: String = "stable") async throws -> VerifiedFirmwareManifest {
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FirmwareManifestError.unauthorized
        }
        guard let baseURL = URL(string: baseURLString) else { throw FirmwareManifestError.badResponse }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/firmware/manifest"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "hardware", value: FirmwareManifestVerifier.expectedHardware),
            URLQueryItem(name: "channel", value: channel)
        ]
        guard let url = components?.url else { throw FirmwareManifestError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FirmwareManifestError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw FirmwareManifestError.unauthorized }
            if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw FirmwareManifestError.server(envelope.code)
            }
            throw FirmwareManifestError.server("HTTP \(http.statusCode)")
        }

        let manifest = try JSONDecoder().decode(FirmwareManifest.self, from: data)
        try verifier.verify(manifest)
        let artifactURL = try FirmwareArtifactURLPolicy.resolve(
            manifest.artifactURL,
            baseURLString: baseURLString,
            requireHTTPS: AppEnvironment.current.isProduction
        )
        return VerifiedFirmwareManifest(manifest: manifest, artifactURL: artifactURL)
    }
}

struct RadarBLEFirmwareStatus: Codable, Hashable {
    var protocolVersion: Int
    var firmwareVersion: String?
    var build: Int?
    var hardware: String?
    var stage: String
    var progress: Int
    var receivedBytes: Int?
    var totalBytes: Int?
    var targetVersion: String?
    var targetBuild: Int?
    var errorCode: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "v"
        case firmwareVersion = "fw"
        case firmwareVersionLong = "firmware_version"
        case build = "b"
        case buildLong = "build"
        case hardware = "h"
        case hardwareLong = "hardware"
        case stage = "s"
        case stageLong = "stage"
        case progress = "p"
        case progressLong = "progress"
        case receivedBytes = "rx"
        case receivedBytesLong = "received_bytes"
        case totalBytes = "z"
        case totalBytesLong = "total_bytes"
        case targetVersion = "tv"
        case targetVersionLong = "target_version"
        case targetBuild = "tb"
        case targetBuildLong = "target_build"
        case errorCode = "e"
        case errorCodeLong = "error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        firmwareVersion = try container.decodeIfPresent(String.self, forKey: .firmwareVersion)
            ?? container.decodeIfPresent(String.self, forKey: .firmwareVersionLong)
        build = try Self.decodeInt(container, short: .build, long: .buildLong)
        hardware = try container.decodeIfPresent(String.self, forKey: .hardware)
            ?? container.decodeIfPresent(String.self, forKey: .hardwareLong)
        stage = try container.decodeIfPresent(String.self, forKey: .stage)
            ?? container.decodeIfPresent(String.self, forKey: .stageLong)
            ?? "idle"
        progress = min(100, max(0, try Self.decodeInt(container, short: .progress, long: .progressLong) ?? 0))
        receivedBytes = try Self.decodeInt(container, short: .receivedBytes, long: .receivedBytesLong)
        totalBytes = try Self.decodeInt(container, short: .totalBytes, long: .totalBytesLong)
        targetVersion = try container.decodeIfPresent(String.self, forKey: .targetVersion)
            ?? container.decodeIfPresent(String.self, forKey: .targetVersionLong)
        targetBuild = try Self.decodeInt(container, short: .targetBuild, long: .targetBuildLong)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
            ?? container.decodeIfPresent(String.self, forKey: .errorCodeLong)
    }

    init(
        protocolVersion: Int = 1,
        firmwareVersion: String? = nil,
        build: Int? = nil,
        hardware: String? = nil,
        stage: String = "idle",
        progress: Int = 0,
        receivedBytes: Int? = nil,
        totalBytes: Int? = nil,
        targetVersion: String? = nil,
        targetBuild: Int? = nil,
        errorCode: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.firmwareVersion = firmwareVersion
        self.build = build
        self.hardware = hardware
        self.stage = stage
        self.progress = progress
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.targetVersion = targetVersion
        self.targetBuild = targetBuild
        self.errorCode = errorCode
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        short: CodingKeys,
        long: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decode(Int.self, forKey: short) { return value }
        if let value = try? container.decode(Int.self, forKey: long) { return value }
        if let value = try? container.decode(String.self, forKey: short) { return Int(value) }
        if let value = try? container.decode(String.self, forKey: long) { return Int(value) }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(firmwareVersion, forKey: .firmwareVersion)
        try container.encodeIfPresent(build, forKey: .build)
        try container.encodeIfPresent(hardware, forKey: .hardware)
        try container.encode(stage, forKey: .stage)
        try container.encode(progress, forKey: .progress)
        try container.encodeIfPresent(receivedBytes, forKey: .receivedBytes)
        try container.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try container.encodeIfPresent(targetVersion, forKey: .targetVersion)
        try container.encodeIfPresent(targetBuild, forKey: .targetBuild)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
    }
}

enum FirmwareUpdatePhase: String, Codable, Hashable {
    case idle
    case checking
    case upToDate
    case available
    case sending
    case canceling
    case downloading
    case verifying
    case installing
    case rebooting
    case succeeded
    case failed
    case bootstrapRequired
    case rolledBack
    case canceled

    var isBusy: Bool {
        [.checking, .sending, .canceling, .downloading, .verifying, .installing, .rebooting].contains(self)
    }
}

@MainActor
@Observable
final class FirmwareUpdateCoordinator {
    @ObservationIgnored private var repository: FirmwareManifestRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sendingAcknowledgementTimeout: Duration
    @ObservationIgnored private var sendingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private static let persistenceKey = "dragonRadar.ota.transaction.v1"

    var phase: FirmwareUpdatePhase = .idle
    var availableRelease: VerifiedFirmwareManifest?
    var firmwareStatus: RadarBLEFirmwareStatus?
    var progress = 0
    var detail = "尚未检查更新"
    var lastError: String?
    var lastCheckedAt: Date?

    init(
        repository: FirmwareManifestRepository = FirmwareManifestRepository(),
        defaults: UserDefaults = .standard,
        sendingAcknowledgementTimeout: Duration = .seconds(12)
    ) {
        self.repository = repository
        self.defaults = defaults
        self.sendingAcknowledgementTimeout = sendingAcknowledgementTimeout
        restore()
        if phase == .sending {
            beginSendingAcknowledgementTimeout()
        } else if phase == .canceling {
            beginCancellationAcknowledgementTimeout()
        }
    }

    var targetVersion: String? { availableRelease?.manifest.version ?? firmwareStatus?.targetVersion }

    func checkForUpdates(accessToken: String, deviceStatus: RadarBLEDeviceStatus?) async {
        cancelSendingTimeout()
        phase = .checking
        availableRelease = nil
        progress = 0
        detail = "正在获取并验证固件清单"
        lastError = nil
        do {
            let release = try await repository.fetch(accessToken: accessToken)
            availableRelease = release
            lastCheckedAt = Date()
            evaluate(release: release, deviceStatus: deviceStatus)
        } catch {
            fail(error.localizedDescription)
        }
        persist()
    }

    func startUpdate(bleBridge: BLEDeviceBridge) {
        guard let release = availableRelease else {
            fail("请先检查固件更新")
            return
        }
        guard bleBridge.deviceStatus?.isOTAProvisioningReady == true else {
            fail("雷达尚未完成绑定和服务器配置")
            return
        }
        guard bleBridge.deviceStatus?.isOTAOriginConfirmed == true else {
            fail("雷达尚未确认固件更新源与 HTTP API 同源")
            bleBridge.readDeviceStatus()
            return
        }
        guard bleBridge.supportsFirmwareOTA else {
            phase = .bootstrapRequired
            detail = "当前固件没有无线更新通道，需要先通过 USB 初始化一次"
            persist()
            return
        }
        guard bleBridge.deviceStatus?.wifi == "connected" else {
            fail("雷达尚未连接 Wi-Fi")
            return
        }
        guard bleBridge.deviceStatus?.isOTAPowerReady == true else {
            fail("雷达需处于充电中，或电量达到 30% 后才能更新")
            return
        }
        if let hardware = bleBridge.reportedHardware, hardware != FirmwareManifestVerifier.expectedHardware {
            fail("固件与当前雷达硬件不匹配")
            return
        }
        guard
            let currentVersionText = bleBridge.reportedFirmwareVersion,
            let currentVersion = FirmwareSemanticVersion(currentVersionText),
            let minimumVersion = release.manifest.minimumSemanticVersion,
            currentVersion >= minimumVersion
        else {
            phase = .bootstrapRequired
            detail = "当前固件不满足无线升级最低基线"
            persist()
            return
        }
        guard
            let currentBuild = bleBridge.deviceStatus?.firmwareBuild ?? bleBridge.firmwareStatus?.build,
            release.manifest.build > currentBuild
        else {
            fail("目标构建号必须大于当前构建号")
            return
        }
        if
            let currentSecurityCounter = bleBridge.deviceStatus?.securityCounter,
            release.manifest.securityCounter < currentSecurityCounter
        {
            fail("目标安全计数器低于当前雷达，已阻止更新")
            return
        }
        guard bleBridge.writeFirmwareStart(release) else {
            fail(bleBridge.lastWriteEvent)
            return
        }
        phase = .sending
        progress = 0
        detail = "已发送签名清单，等待雷达开始下载"
        lastError = nil
        beginSendingAcknowledgementTimeout()
        persist()
    }

    func retry(bleBridge: BLEDeviceBridge) {
        startUpdate(bleBridge: bleBridge)
    }

    func cancel(bleBridge: BLEDeviceBridge) {
        guard [.sending, .downloading, .verifying].contains(phase) else { return }
        if bleBridge.writeFirmwareAction("cancel") {
            cancelSendingTimeout()
            phase = .canceling
            detail = "取消请求已发送，等待雷达确认"
            beginCancellationAcknowledgementTimeout()
            persist()
        } else {
            fail(bleBridge.lastWriteEvent)
        }
    }

    func refreshFromDevice(bleBridge: BLEDeviceBridge) {
        guard bleBridge.isBLEConnected else {
            synchronize(status: bleBridge.firmwareStatus, deviceStatus: bleBridge.deviceStatus)
            return
        }
        bleBridge.readDeviceStatus()
        bleBridge.readFirmwareStatus()
        synchronize(status: bleBridge.firmwareStatus, deviceStatus: bleBridge.deviceStatus)
    }

    func synchronize(status: RadarBLEFirmwareStatus?, deviceStatus: RadarBLEDeviceStatus?) {
        if let status {
            firmwareStatus = status
            progress = status.progress
            let stage = status.stage.lowercased()
            if stage != "idle" && phase != .canceling {
                cancelSendingTimeout()
            }
            switch stage {
            case "checking":
                if phase == .canceling { detail = "已请求取消，雷达仍在检查固件" }
                else { phase = .sending; detail = "雷达正在检查固件" }
            case "downloading":
                if phase == .canceling { detail = "已请求取消，等待雷达停止下载" }
                else { phase = .downloading; detail = "雷达正在下载固件" }
            case "verifying":
                if phase == .canceling { detail = "已请求取消，等待雷达停止校验" }
                else { phase = .verifying; detail = "雷达正在校验签名与完整性" }
            case "pending":
                if phase == .canceling { detail = "取消尚未确认；雷达已进入启动确认阶段" }
                else { phase = .installing; detail = "新固件已启动，等待雷达健康确认" }
            case "rebooting":
                if phase == .canceling { detail = "取消尚未确认；雷达正在重启" }
                else { phase = .rebooting; detail = "雷达正在重启并确认新版本" }
            case "success":
                cancelSendingTimeout()
                if
                    let expectedVersion = targetVersion,
                    let expectedBuild = availableRelease?.manifest.build ?? status.targetBuild,
                    status.firmwareVersion == expectedVersion,
                    status.build == expectedBuild,
                    status.targetVersion == expectedVersion,
                    status.targetBuild == expectedBuild
                {
                    phase = .succeeded
                    progress = 100
                    detail = "雷达已完成健康确认并标记新固件有效"
                } else {
                    fail("雷达报告更新成功，但版本或构建号与目标不一致")
                }
            case "error": fail(status.errorCode.map { "雷达更新失败：\($0)" } ?? "雷达更新失败")
            case "rollback":
                cancelSendingTimeout()
                phase = .rolledBack
                detail = "新固件未通过启动确认，雷达已回滚"
            case "cancelled", "canceled":
                cancelSendingTimeout()
                phase = .canceled
                detail = "雷达已取消更新"
            case "idle": break
            default: break
            }
        }

        if
            let target = targetVersion,
            let installed = deviceStatus?.firmwareVersion ?? status?.firmwareVersion,
            installed == target,
            phase == .rebooting || phase == .installing || phase == .sending || phase == .verifying
        {
            phase = .rebooting
            detail = "已发现目标版本 \(installed)，等待雷达 108 健康确认"
        }
        persist()
    }

    func reset() {
        cancelSendingTimeout()
        phase = .idle
        availableRelease = nil
        firmwareStatus = nil
        progress = 0
        detail = "尚未检查更新"
        lastError = nil
        lastCheckedAt = nil
        defaults.removeObject(forKey: Self.persistenceKey)
    }

    func handleDeviceReadinessFailure(_ message: String) {
        availableRelease = nil
        progress = 0
        fail(message)
    }

    func evaluate(release: VerifiedFirmwareManifest, deviceStatus: RadarBLEDeviceStatus?) {
        let installedText = deviceStatus?.firmwareVersion ?? firmwareStatus?.firmwareVersion
        guard let installedText, let installed = FirmwareSemanticVersion(installedText) else {
            phase = .bootstrapRequired
            detail = "当前固件无法确认安全升级基线，需要先通过 USB 初始化一次"
            return
        }
        guard let minimum = release.manifest.minimumSemanticVersion, installed >= minimum else {
            phase = .bootstrapRequired
            detail = "当前版本低于无线升级最低版本 \(release.manifest.minimumVersion)，需要 USB 初始化"
            return
        }
        guard let target = release.manifest.semanticVersion else {
            fail("服务端固件版本无效")
            return
        }
        guard let currentBuild = deviceStatus?.firmwareBuild ?? firmwareStatus?.build else {
            fail("当前固件构建号未上报，暂不能判断是否可更新")
            return
        }
        guard release.manifest.build > currentBuild else {
            if installed >= target {
                phase = .upToDate
                detail = "当前构建号 \(currentBuild) 不低于发布构建号 \(release.manifest.build)"
            } else {
                fail("发布构建号必须全局大于当前构建号 \(currentBuild)")
            }
            return
        }
        if
            let currentSecurityCounter = deviceStatus?.securityCounter,
            release.manifest.securityCounter < currentSecurityCounter
        {
            fail("发布安全计数器低于当前值 \(currentSecurityCounter)")
            return
        }
        if installed < target || (installed == target && currentBuild < release.manifest.build) {
            phase = .available
            detail = "发现版本 \(release.manifest.version)（构建 \(release.manifest.build)）"
        } else {
            phase = .upToDate
            detail = "当前已是最新版本 \(installedText)"
        }
    }

    private func fail(_ message: String) {
        cancelSendingTimeout()
        phase = .failed
        lastError = message
        detail = message
        persist()
    }

    func handleFirmwareControlWriteFailure(_ message: String) {
        guard phase == .sending || phase == .canceling else { return }
        fail(message)
    }

    func beginSendingAcknowledgementTimeout() {
        cancelSendingTimeout()
        let timeout = sendingAcknowledgementTimeout
        sendingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.phase == .sending else { return }
            self.sendingTimeoutTask = nil
            self.fail("雷达未在限定时间内确认固件控制，请重新连接后重试")
        }
    }

    func beginCancellationAcknowledgementTimeout() {
        cancelSendingTimeout()
        let timeout = sendingAcknowledgementTimeout
        sendingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.phase == .canceling else { return }
            self.sendingTimeoutTask = nil
            self.fail("雷达未在限定时间内确认取消，实际更新状态未知；请重新连接并读取状态")
        }
    }

    private func cancelSendingTimeout() {
        sendingTimeoutTask?.cancel()
        sendingTimeoutTask = nil
    }

    private struct PersistedState: Codable {
        var phase: FirmwareUpdatePhase
        var release: FirmwareManifest?
        var artifactURL: URL?
        var status: RadarBLEFirmwareStatus?
        var progress: Int
        var detail: String
        var lastError: String?
        var lastCheckedAt: Date?
    }

    private func persist() {
        let state = PersistedState(
            phase: phase,
            release: availableRelease?.manifest,
            artifactURL: availableRelease?.artifactURL,
            status: firmwareStatus,
            progress: progress,
            detail: detail,
            lastError: lastError,
            lastCheckedAt: lastCheckedAt
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }

    private func restore() {
        guard
            let data = defaults.data(forKey: Self.persistenceKey),
            let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        phase = state.phase
        if let manifest = state.release, let artifactURL = state.artifactURL {
            availableRelease = VerifiedFirmwareManifest(manifest: manifest, artifactURL: artifactURL)
        }
        firmwareStatus = state.status
        progress = state.progress
        detail = state.detail
        lastError = state.lastError
        lastCheckedAt = state.lastCheckedAt
    }
}
