import CoreBluetooth
import CryptoKit
import Foundation
import Observation
import Security

enum RadarBLECharacteristic: String, CaseIterable, Identifiable {
    case pairingChallenge = "pairing_challenge"
    case pairingResponse = "pairing_response"
    case wifiConfig = "wifi_config"
    case localLocation = "local_location"
    case deviceStatus = "device_status"
    case serverConfig = "server_config"
    case firmwareControl = "firmware_control"
    case firmwareStatus = "firmware_status"
    case voiceControl = "voice_control"
    case voiceAudioUplink = "voice_audio_uplink"
    case voiceAudioDownlink = "voice_audio_downlink"

    var id: String { rawValue }

    var uuid: CBUUID {
        switch self {
        case .pairingChallenge:
            CBUUID(string: "7d540101-f82d-4b2f-91c6-4f0f88aa5a11")
        case .pairingResponse:
            CBUUID(string: "7d540102-f82d-4b2f-91c6-4f0f88aa5a11")
        case .wifiConfig:
            CBUUID(string: "7d540103-f82d-4b2f-91c6-4f0f88aa5a11")
        case .localLocation:
            CBUUID(string: "7d540104-f82d-4b2f-91c6-4f0f88aa5a11")
        case .deviceStatus:
            CBUUID(string: "7d540105-f82d-4b2f-91c6-4f0f88aa5a11")
        case .serverConfig:
            CBUUID(string: "7d540106-f82d-4b2f-91c6-4f0f88aa5a11")
        case .firmwareControl:
            CBUUID(string: "7d540107-f82d-4b2f-91c6-4f0f88aa5a11")
        case .firmwareStatus:
            CBUUID(string: "7d540108-f82d-4b2f-91c6-4f0f88aa5a11")
        case .voiceControl:
            CBUUID(string: "7d540109-f82d-4b2f-91c6-4f0f88aa5a11")
        case .voiceAudioUplink:
            CBUUID(string: "7d54010a-f82d-4b2f-91c6-4f0f88aa5a11")
        case .voiceAudioDownlink:
            CBUUID(string: "7d54010b-f82d-4b2f-91c6-4f0f88aa5a11")
        }
    }

    var title: String {
        rawValue
    }

    static let requiredProvisioningRoles: [Self] = [
        .pairingChallenge,
        .pairingResponse,
        .wifiConfig,
        .localLocation,
        .deviceStatus,
        .serverConfig
    ]
}

struct BLEDeviceCandidate: Identifiable, Hashable {
    var peripheralID: UUID
    var name: String
    var rssi: Int
    var isConnectable: Bool
    var serviceHint: String
    var lastSeen: Date

    var id: UUID { peripheralID }

    var rssiText: String {
        "\(rssi) dBm"
    }

    var lastSeenText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(lastSeen)))
        return seconds < 2 ? "刚刚" : "\(seconds) 秒前"
    }
}

struct RadarBLEDeviceStatus: Decodable, Hashable {
    var v: Int
    var name: String
    var ble: Int
    var bleSecure: Int?
    var paired: Int
    var wifi: String
    var rssi: Int
    var ip: String
    var server: Int
    var relay: String?
    var loc: Int
    var battery: DeviceBatterySnapshot?
    var batteryPercent: Int?
    var batteryVoltageMV: Int?
    var last: String
    var firmwareVersion: String?
    var firmwareBuild: Int?
    var hardware: String?
    var capabilities: [String]?
    var otaCapable: Int?
    var otaOrigin: Int?
    var securityCounter: Int?
    var ownerAuthRequired: Int?
    var ownerAuth: Int?

    enum CodingKeys: String, CodingKey {
        case v
        case name
        case ble
        case bleSecure = "ble_secure"
        case paired
        case wifi
        case rssi
        case ip
        case server
        case relay
        case loc
        case battery
        case batteryPercent = "battery_percent"
        case batteryVoltageMV = "battery_voltage_mv"
        case last
        case firmwareVersion = "fw"
        case firmwareBuild = "build"
        case hardware = "hw"
        case capabilities
        case otaCapable = "ota"
        case otaOrigin = "ota_origin"
        case securityCounter = "security_counter"
        case ownerAuthRequired = "owner_auth_required"
        case ownerAuth = "owner_auth"
    }

    var bleText: String { ble == 1 ? "BLE 配置通道已连接" : "BLE 配置通道未连接" }
    var bleSecurityText: String { bleSecure == 1 ? "系统加密配对已完成" : "等待系统加密配对" }
    var pairedText: String { paired == 1 ? "已绑定" : "未绑定" }
    var serverText: String { server == 1 ? "已配置" : "未配置" }
    var locationText: String { loc == 1 ? "已收到" : "未收到" }
    var relayText: String { relay ?? "未知" }
    var batteryPercentValue: Int? {
        if let percent = battery?.percent, percent >= 0 {
            return percent
        }
        if let batteryPercent, batteryPercent >= 0 {
            return batteryPercent
        }
        return nil
    }
    var batteryText: String {
        if let battery, battery.displayText != "未上报" {
            return battery.displayText
        }
        guard let percent = batteryPercentValue else {
            return "未上报"
        }
        if let batteryVoltageMV, batteryVoltageMV > 0 {
            return "\(percent)% · \(batteryVoltageMV)mV"
        }
        return "\(percent)%"
    }
    var wifiText: String {
        if wifi == "connected" {
            return ip.isEmpty ? "connected" : "\(ip) · \(rssi)dBm"
        }
        return wifi
    }

    var firmwareText: String {
        guard let firmwareVersion, !firmwareVersion.isEmpty else { return "未上报" }
        if let firmwareBuild { return "\(firmwareVersion)（\(firmwareBuild)）" }
        return firmwareVersion
    }

    var supportsOTA: Bool {
        if otaCapable == 1 { return true }
        let values = capabilities ?? []
        return values.contains("ota_pull") && values.contains("ota_confirm")
    }

    var isOTAPowerReady: Bool {
        battery?.charging == true || (batteryPercentValue ?? -1) >= 30
    }

    var isOTAProvisioningReady: Bool {
        paired == 1 && server == 1
    }

    var isOTAOriginConfirmed: Bool {
        otaOrigin == 1
    }
}

enum BLEPairingTransactionGate {
    static func pairingResponseAccepted(
        status: RadarBLEDeviceStatus?,
        statusAt: Date?,
        startedAt: Date,
        ownerSessionAuthorized: Bool
    ) -> Bool {
        guard
            let status,
            let statusAt,
            statusAt >= startedAt
        else { return false }
        return status.last == "pairing_response_verified"
            && status.paired == 1
            && status.ownerAuth == 1
            && ownerSessionAuthorized
    }

    static func pairingResponseRejected(
        status: RadarBLEDeviceStatus?,
        statusAt: Date?,
        startedAt: Date
    ) -> Bool {
        guard
            let status,
            let statusAt,
            statusAt >= startedAt
        else { return false }
        return status.last == "pairing_response locked"
            || status.last == "pairing_response invalid"
    }

    static func serverConfigAccepted(
        status: RadarBLEDeviceStatus?,
        statusAt: Date?,
        startedAt: Date,
        ownerSessionAuthorized: Bool
    ) -> Bool {
        guard
            let status,
            let statusAt,
            statusAt >= startedAt
        else { return false }
        return status.server == 1
            && status.ownerAuth == 1
            && ownerSessionAuthorized
    }
}

enum BLEOwnerSessionProof {
    static func make(
        challenge: String,
        deviceToken: String,
        nonce: String? = nil
    ) -> String? {
        let cleanChallenge = challenge.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanChallenge.hasPrefix("CR-"), !cleanToken.isEmpty else { return nil }
        guard let cleanNonce = nonce ?? randomNonce(), (16...64).contains(cleanNonce.count) else { return nil }

        let message = "v1|\(cleanChallenge)|t|\(cleanNonce)"
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(cleanToken.utf8))
        )
        let proof = authenticationCode.map { String(format: "%02x", $0) }.joined()
        return "dra-auth:v1:t:\(cleanNonce):\(proof)"
    }

    private static func randomNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct RadarBLEServerConfigPayload: Encodable, Hashable {
    var version = "1"
    var relayURL: String
    var httpAPIURL: String
    var roomToken: String
    var deviceToken: String

    enum CodingKeys: String, CodingKey {
        case version
        case relayURL = "relay_url"
        case httpAPIURL = "http_api_url"
        case roomToken = "room_token"
        case deviceToken = "device_token"
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    var redactedLogText: String {
        "正在写入服务器配置 · relay=\(relayURL) · http_api=\(httpAPIURL) · 敏感凭证已省略"
    }
}

@MainActor
@Observable
final class BLEDeviceBridge: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristics: [RadarBLECharacteristic: CBCharacteristic] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var scanTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var firmwareReconnectRetryTask: Task<Void, Never>?
    @ObservationIgnored private var firmwareReconnectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var firmwareReconnectCancellationTask: Task<Void, Never>?
    @ObservationIgnored private var firmwareReconnectTargetID: UUID?
    @ObservationIgnored private var firmwareReconnectWindowStartedAt: Date?
    @ObservationIgnored private var firmwareReconnectAttemptsStarted = 0
    @ObservationIgnored private var firmwareReconnectTrackingRequired = false
    @ObservationIgnored private var firmwareReconnectSuppressed = false
    @ObservationIgnored private var firmwareReconnectInFlight = false
    @ObservationIgnored private var firmwareReconnectAwaitingCancellation = false
    @ObservationIgnored private var ownerDeviceToken = ""
    @ObservationIgnored private var ownerAuthAttemptChallenge: String?
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var authorizedAccessoryConnection: (identifier: UUID, name: String)?
    @ObservationIgnored private var manualDisconnectRequested = false
    @ObservationIgnored private var gatewayReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var voiceDownlinkQueue: [Data] = []
    @ObservationIgnored private var voiceGatewayAnnounced = false
    @ObservationIgnored private var voiceControlHandler: ((Data) -> Void)?
    @ObservationIgnored private var voiceUplinkHandler: ((Data) -> Void)?

    let radarServiceUUID = CBUUID(string: "7d540100-f82d-4b2f-91c6-4f0f88aa5a11")

    var candidates: [BLEDeviceCandidate] = []
    var isScanning = false
    var selectedPeripheralID: UUID?
    var connectedPeripheralName = "未连接"
    var discoveredCharacteristics: [String] = []
    var availableCharacteristicNames: [String] = []
    var pairingChallengeText = "未读取"
    var deviceStatusText = "未读取"
    var deviceStatus: RadarBLEDeviceStatus?
    var lastDeviceStatusAt: Date?
    var firmwareStatusText = "未读取"
    var firmwareStatus: RadarBLEFirmwareStatus?
    var lastFirmwareStatusAt: Date?
    var firmwareControlWriteError: String?
    var firmwareReconnectText = "未启用"
    var ownerSessionAuthorized = false
    var lastWriteEvent = "尚未写入雷达" {
        didSet { bleEventHistory = Self.append(lastWriteEvent, to: bleEventHistory) }
    }
    var lastEvent = "蓝牙尚未开始" {
        didSet { bleEventHistory = Self.append(lastEvent, to: bleEventHistory) }
    }
    var bleEventHistory: [String] = []
    var centralState: CBManagerState = .unknown
    var persistedPaired = false
    var persistedServerConfigured = false
    var persistedDeviceName = "未注册"
    var voiceGatewayText = "等待雷达语音通道"
    var voiceUplinkFrames = 0
    var voiceDownlinkFrames = 0
    var voiceDroppedFrames = 0
    var scanTimedOut = false
    private var scanStartedAt: Date?

    override init() {
        super.init()
        persistedPaired = defaults.bool(forKey: Self.persistedPairedKey)
        persistedServerConfigured = defaults.bool(forKey: Self.persistedServerConfiguredKey)
        persistedDeviceName = defaults.string(forKey: Self.persistedDeviceNameKey) ?? "未注册"
        ensureCentralManager()
    }

    private static let persistedPairedKey = "dragonRadar.esp.paired"
    private static let persistedServerConfiguredKey = "dragonRadar.esp.serverConfigured"
    private static let persistedDeviceNameKey = "dragonRadar.esp.deviceName"
    private static let firmwareReconnectTargetKey = "dragonRadar.ota.reconnect.peripheralID"
    private static let firmwareReconnectWindowKey = "dragonRadar.ota.reconnect.windowStartedAt"
    private static let firmwareReconnectAttemptsKey = "dragonRadar.ota.reconnect.attemptsStarted"
    private static let gatewayPeripheralKey = "dragonRadar.gateway.peripheralID"
    private static let centralRestorationID = "com.dragonradar.mvp.ble-gateway"

    private static func append(_ value: String, to history: [String]) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return Array(([ "\(stamp) \(trimmed)" ] + history).prefix(20))
    }

    var isBLEConnected: Bool {
        guard let selectedPeripheralID, let peripheral = peripherals[selectedPeripheralID] else {
            return false
        }
        return peripheral.state == .connected
    }

    var supportsFirmwareOTA: Bool {
        guard hasCharacteristic(.firmwareControl), hasCharacteristic(.firmwareStatus) else { return false }
        if deviceStatus?.otaCapable == 0 { return false }
        return true
    }

    var isVoiceGatewayReady: Bool {
        isBLEConnected
            && ownerSessionAuthorized
            && hasCharacteristic(.voiceControl)
            && hasCharacteristic(.voiceAudioUplink)
            && hasCharacteristic(.voiceAudioDownlink)
    }

    func configureVoiceGateway(
        onControl: @escaping (Data) -> Void,
        onUplinkFrame: @escaping (Data) -> Void
    ) {
        voiceControlHandler = onControl
        voiceUplinkHandler = onUplinkFrame
        activateVoiceGatewayIfReady()
    }

    var reportedFirmwareVersion: String? {
        deviceStatus?.firmwareVersion ?? firmwareStatus?.firmwareVersion
    }

    var reportedHardware: String? {
        deviceStatus?.hardware ?? firmwareStatus?.hardware
    }

    func configureOwnerSession(deviceToken: String) {
        let cleanToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanToken != ownerDeviceToken else {
            authorizeOwnerSessionIfPossible()
            return
        }
        ownerDeviceToken = cleanToken
        ownerAuthAttemptChallenge = nil
        ownerSessionAuthorized = false
        authorizeOwnerSessionIfPossible()
    }

    func recoverOwnerSession(deviceTokens: [String]) async -> String? {
        guard deviceStatus?.paired == 1, deviceStatus?.ownerAuthRequired == 1 else { return nil }
        if ownerSessionAuthorized {
            return ownerDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var seen = Set<String>()
        let candidates = deviceTokens.compactMap { token -> String? in
            let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanToken.isEmpty, seen.insert(cleanToken).inserted else { return nil }
            return cleanToken
        }

        for token in candidates {
            configureOwnerSession(deviceToken: "")
            try? await Task.sleep(for: .milliseconds(200))
            configureOwnerSession(deviceToken: token)

            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if ownerSessionAuthorized, deviceStatus?.ownerAuth == 1 {
                    return token
                }
                readDeviceStatus()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        configureOwnerSession(deviceToken: "")
        return nil
    }

    func confirmPairingResponse(
        startedAt: Date,
        timeoutSeconds: TimeInterval = 6
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if BLEPairingTransactionGate.pairingResponseAccepted(
                status: deviceStatus,
                statusAt: lastDeviceStatusAt,
                startedAt: startedAt,
                ownerSessionAuthorized: ownerSessionAuthorized
            ) {
                return true
            }
            if BLEPairingTransactionGate.pairingResponseRejected(
                status: deviceStatus,
                statusAt: lastDeviceStatusAt,
                startedAt: startedAt
            ) {
                return false
            }
            readDeviceStatus()
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    func confirmServerConfig(
        deviceToken: String,
        startedAt: Date,
        timeoutSeconds: TimeInterval = 8
    ) async -> Bool {
        let cleanToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { return false }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var freshOwnerProofStarted = false
        while Date() < deadline {
            if
                let statusAt = lastDeviceStatusAt,
                statusAt >= startedAt,
                deviceStatus?.server == 1,
                !freshOwnerProofStarted
            {
                // Force a new HMAC proof. Success proves the ESP actually saved
                // this transaction's token instead of merely acknowledging the
                // GATT write while retaining an older token.
                freshOwnerProofStarted = true
                configureOwnerSession(deviceToken: "")
                try? await Task.sleep(for: .milliseconds(200))
                configureOwnerSession(deviceToken: cleanToken)
            }
            if
                freshOwnerProofStarted,
                BLEPairingTransactionGate.serverConfigAccepted(
                    status: deviceStatus,
                    statusAt: lastDeviceStatusAt,
                    startedAt: startedAt,
                    ownerSessionAuthorized: ownerSessionAuthorized
                )
            {
                return true
            }
            readDeviceStatus()
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func authorizeOwnerSessionIfPossible() {
        guard deviceStatus?.paired == 1, deviceStatus?.ownerAuthRequired == 1 else { return }
        guard !ownerSessionAuthorized, ownerAuthAttemptChallenge != pairingChallengeText else { return }
        guard hasCharacteristic(.pairingResponse) else { return }
        guard let response = BLEOwnerSessionProof.make(
            challenge: pairingChallengeText,
            deviceToken: ownerDeviceToken
        ) else { return }

        ownerAuthAttemptChallenge = pairingChallengeText
        if !writeString(response, role: .pairingResponse) {
            ownerAuthAttemptChallenge = nil
        }
    }

    private var firmwareOwnerSessionReady: Bool {
        deviceStatus?.ownerAuthRequired != 1 || ownerSessionAuthorized
    }

    func hasCharacteristic(_ role: RadarBLECharacteristic) -> Bool {
        characteristics[role] != nil
    }

    func refreshCharacteristics() {
        guard
            let selectedPeripheralID,
            let peripheral = peripherals[selectedPeripheralID]
        else {
            lastEvent = "未连接雷达，无法重新检测"
            return
        }
        characteristics.removeAll()
        discoveredCharacteristics.removeAll()
        availableCharacteristicNames.removeAll()
        lastEvent = "重新检测雷达连接"
        if let services = peripheral.services, !services.isEmpty {
            for service in services where service.uuid == radarServiceUUID {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        } else {
            peripheral.discoverServices([radarServiceUUID])
        }
    }

    func readDeviceStatus() {
        guard
            let selectedPeripheralID,
            let peripheral = peripherals[selectedPeripheralID],
            let characteristic = characteristics[.deviceStatus]
        else {
            refreshCharacteristics()
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func readFirmwareStatus() {
        guard
            let selectedPeripheralID,
            let peripheral = peripherals[selectedPeripheralID],
            let characteristic = characteristics[.firmwareStatus]
        else { return }
        peripheral.readValue(for: characteristic)
    }

    var isRegistrationComplete: Bool {
        (deviceStatus?.paired == 1 || persistedPaired)
            && (deviceStatus?.server == 1 || persistedServerConfigured)
    }

    var hasSavedRegistration: Bool {
        persistedPaired && persistedServerConfigured
    }

    var hasLiveDeviceStatus: Bool {
        deviceStatus != nil
    }

    var isLiveNetworkConfirmed: Bool {
        guard let deviceStatus else { return false }
        return deviceStatus.wifi == "connected" && deviceStatus.server == 1
    }

    var registrationText: String {
        if let deviceStatus {
            if deviceStatus.paired == 1, deviceStatus.server == 1 {
                return "已绑定 · 雷达当前已确认"
            }
            if deviceStatus.paired == 1 {
                return "已绑定 · 等待联网配置"
            }
        }
        if hasSavedRegistration {
            return "上次已绑定 · 当前未确认"
        }
        if persistedPaired {
            return "上次已绑定 · 还没保存完整配置"
        }
        return "未绑定"
    }

    var authorizationText: String {
        switch CBCentralManager.authorization {
        case .allowedAlways:
            "已授权"
        case .denied:
            "已拒绝"
        case .restricted:
            "受限制"
        case .notDetermined:
            "待授权"
        @unknown default:
            "未知"
        }
    }

    var stateText: String {
        switch centralState {
        case .poweredOn:
            "可用"
        case .poweredOff:
            "蓝牙关闭"
        case .unauthorized:
            "未授权"
        case .unsupported:
            "不支持"
        case .resetting:
            "重置中"
        case .unknown:
            "未知"
        @unknown default:
            "未知"
        }
    }

    func startScan() {
        if authorizedAccessoryConnection != nil {
            connectAuthorizedAccessoryIfReady()
            return
        }
        scanRequested = true
        ensureCentralManager()
        guard let central else { return }
        guard central.state == .poweredOn else {
            lastEvent = central.state == .unknown ? "正在请求蓝牙访问" : "蓝牙不可用：\(stateText)"
            return
        }

        scanRequested = false
        resetStateForNewScan()
        scanStartedAt = Date()
        isScanning = true
        lastEvent = "正在查找附近的雷达"
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        startScanTimeout()
    }

    private func resetStateForNewScan() {
        candidates.removeAll()
        discoveredCharacteristics.removeAll()
        availableCharacteristicNames.removeAll()
        characteristics.removeAll()
        deviceStatus = nil
        deviceStatusText = "未读取"
        firmwareStatusText = "未读取"
        firmwareStatus = nil
        lastFirmwareStatusAt = nil
        pairingChallengeText = "未读取"
        ownerSessionAuthorized = false
        ownerAuthAttemptChallenge = nil
        scanTimedOut = false
    }

    func stopScan() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        scanStartedAt = nil
        central?.stopScan()
        isScanning = false
        lastEvent = candidates.isEmpty ? "未找到雷达" : "发现 \(candidates.count) 台雷达"
    }

    private func startScanTimeout() {
        scanTimeoutTask?.cancel()
        let startedAt = scanStartedAt
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            self?.finishScanTimeout(startedAt: startedAt)
        }
    }

    private func finishScanTimeout(startedAt: Date?) {
        guard isScanning, candidates.isEmpty, scanStartedAt == startedAt else {
            return
        }
        central?.stopScan()
        isScanning = false
        scanTimedOut = true
        scanStartedAt = nil
        scanTimeoutTask = nil
        lastEvent = "未找到雷达，请确认雷达已开机并靠近手机，然后重试"
    }

    func setFirmwareReconnectTracking(_ required: Bool) {
        guard required else {
            stopFirmwareReconnectTracking(clearTarget: true, suppressed: false)
            return
        }

        if firmwareReconnectTrackingRequired {
            resumeFirmwareReconnectIfNeeded()
            return
        }

        firmwareReconnectTrackingRequired = true
        firmwareReconnectSuppressed = false

        if let selectedPeripheralID {
            captureFirmwareReconnectTarget(selectedPeripheralID)
        } else if
            let rawTarget = defaults.string(forKey: Self.firmwareReconnectTargetKey),
            let targetID = UUID(uuidString: rawTarget)
        {
            firmwareReconnectTargetID = targetID
            firmwareReconnectWindowStartedAt = defaults.object(
                forKey: Self.firmwareReconnectWindowKey
            ) as? Date
            firmwareReconnectAttemptsStarted = defaults.integer(
                forKey: Self.firmwareReconnectAttemptsKey
            )
        }

        guard firmwareReconnectTargetID != nil else {
            firmwareReconnectText = "等待记录 OTA 雷达"
            return
        }
        ensureCentralManager()
        firmwareReconnectText = "已跟踪 OTA 雷达"
        resumeFirmwareReconnectIfNeeded()
    }

    private func captureFirmwareReconnectTarget(_ peripheralID: UUID) {
        let persistedTargetID = defaults.string(forKey: Self.firmwareReconnectTargetKey)
            .flatMap { UUID(uuidString: $0) }
        let changedTarget = firmwareReconnectTargetID != peripheralID && persistedTargetID != peripheralID
        firmwareReconnectTargetID = peripheralID
        defaults.set(peripheralID.uuidString, forKey: Self.firmwareReconnectTargetKey)
        if changedTarget {
            firmwareReconnectWindowStartedAt = nil
            firmwareReconnectAttemptsStarted = 0
            defaults.removeObject(forKey: Self.firmwareReconnectWindowKey)
            defaults.set(0, forKey: Self.firmwareReconnectAttemptsKey)
        } else if firmwareReconnectWindowStartedAt == nil {
            firmwareReconnectWindowStartedAt = defaults.object(
                forKey: Self.firmwareReconnectWindowKey
            ) as? Date
            firmwareReconnectAttemptsStarted = defaults.integer(
                forKey: Self.firmwareReconnectAttemptsKey
            )
        }
    }

    private func stopFirmwareReconnectTracking(clearTarget: Bool, suppressed: Bool) {
        firmwareReconnectRetryTask?.cancel()
        firmwareReconnectTimeoutTask?.cancel()
        firmwareReconnectCancellationTask?.cancel()
        firmwareReconnectRetryTask = nil
        firmwareReconnectTimeoutTask = nil
        firmwareReconnectCancellationTask = nil

        if
            firmwareReconnectInFlight || firmwareReconnectAwaitingCancellation,
            firmwareReconnectTargetID != nil
        {
            if
                let targetID = firmwareReconnectTargetID,
                let peripheral = peripherals[targetID],
                peripheral.state == .connecting
            {
                central?.cancelPeripheralConnection(peripheral)
            }
        }

        firmwareReconnectInFlight = false
        firmwareReconnectAwaitingCancellation = false
        if clearTarget, !suppressed {
            firmwareReconnectTrackingRequired = false
        }
        firmwareReconnectSuppressed = suppressed

        if clearTarget {
            firmwareReconnectTargetID = nil
            firmwareReconnectWindowStartedAt = nil
            firmwareReconnectAttemptsStarted = 0
            defaults.removeObject(forKey: Self.firmwareReconnectTargetKey)
            defaults.removeObject(forKey: Self.firmwareReconnectWindowKey)
            defaults.removeObject(forKey: Self.firmwareReconnectAttemptsKey)
        }
        firmwareReconnectText = suppressed ? "已由用户取消自动重连" : "未启用"
    }

    private func suspendFirmwareReconnectForManualDisconnect() {
        guard firmwareReconnectTrackingRequired else { return }
        stopFirmwareReconnectTracking(clearTarget: false, suppressed: true)
        firmwareReconnectWindowStartedAt = nil
        firmwareReconnectAttemptsStarted = 0
        defaults.removeObject(forKey: Self.firmwareReconnectTargetKey)
        defaults.removeObject(forKey: Self.firmwareReconnectWindowKey)
        defaults.removeObject(forKey: Self.firmwareReconnectAttemptsKey)
    }

    private func resumeFirmwareReconnectIfNeeded() {
        guard
            firmwareReconnectTrackingRequired,
            !firmwareReconnectSuppressed,
            let central,
            central.state == .poweredOn,
            let targetID = firmwareReconnectTargetID
        else { return }

        if let peripheral = firmwareReconnectPeripheral(targetID), peripheral.state == .connected {
            selectedPeripheralID = targetID
            connectedPeripheralName = peripheral.name ?? connectedPeripheralName
            firmwareReconnectText = "OTA 雷达已连接"
            peripheral.delegate = self
            peripheral.discoverServices([radarServiceUUID])
            return
        }

        beginFirmwareReconnectWindowIfNeeded()
        scheduleNextFirmwareReconnectAttempt()
    }

    private func beginFirmwareReconnectWindowIfNeeded() {
        guard firmwareReconnectWindowStartedAt == nil else { return }
        let startedAt = Date()
        firmwareReconnectWindowStartedAt = startedAt
        firmwareReconnectAttemptsStarted = 0
        defaults.set(startedAt, forKey: Self.firmwareReconnectWindowKey)
        defaults.set(0, forKey: Self.firmwareReconnectAttemptsKey)
    }

    private func firmwareReconnectPeripheral(_ peripheralID: UUID) -> CBPeripheral? {
        if let peripheral = peripherals[peripheralID] {
            return peripheral
        }
        guard let central else { return nil }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [peripheralID]).first else {
            return nil
        }
        peripheral.delegate = self
        peripherals[peripheralID] = peripheral
        return peripheral
    }

    private func scheduleNextFirmwareReconnectAttempt() {
        guard
            firmwareReconnectTrackingRequired,
            !firmwareReconnectSuppressed,
            !firmwareReconnectInFlight,
            !firmwareReconnectAwaitingCancellation,
            firmwareReconnectRetryTask == nil,
            let startedAt = firmwareReconnectWindowStartedAt
        else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        guard FirmwareReconnectPolicy.hasBudget(
            attemptsStarted: firmwareReconnectAttemptsStarted,
            elapsed: elapsed
        ) else {
            firmwareReconnectText = "自动重连已停止（已达上限）"
            lastEvent = "OTA 自动重连已达到限定次数或时间，请手动连接雷达读取 105/108 状态"
            return
        }

        let attemptNumber = firmwareReconnectAttemptsStarted + 1
        guard let delay = FirmwareReconnectPolicy.delayBeforeAttempt(attemptNumber) else { return }
        firmwareReconnectText = "等待第 \(attemptNumber) 次 OTA 重连"
        firmwareReconnectRetryTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            self.firmwareReconnectRetryTask = nil
            self.performFirmwareReconnectAttempt(attemptNumber: attemptNumber)
        }
    }

    private func performFirmwareReconnectAttempt(attemptNumber: Int) {
        guard
            firmwareReconnectTrackingRequired,
            !firmwareReconnectSuppressed,
            let central,
            central.state == .poweredOn,
            let targetID = firmwareReconnectTargetID,
            let startedAt = firmwareReconnectWindowStartedAt,
            FirmwareReconnectPolicy.hasBudget(
                attemptsStarted: firmwareReconnectAttemptsStarted,
                elapsed: Date().timeIntervalSince(startedAt)
            )
        else { return }

        firmwareReconnectAttemptsStarted = attemptNumber
        defaults.set(attemptNumber, forKey: Self.firmwareReconnectAttemptsKey)

        guard let peripheral = firmwareReconnectPeripheral(targetID) else {
            firmwareReconnectText = "第 \(attemptNumber) 次未找到原 OTA 雷达"
            scheduleNextFirmwareReconnectAttempt()
            return
        }

        if peripheral.state == .connected {
            selectedPeripheralID = targetID
            connectedPeripheralName = peripheral.name ?? connectedPeripheralName
            firmwareReconnectText = "OTA 雷达已连接"
            peripheral.discoverServices([radarServiceUUID])
            return
        }
        guard peripheral.state == .disconnected else {
            scheduleNextFirmwareReconnectAttempt()
            return
        }

        selectedPeripheralID = targetID
        connectedPeripheralName = peripheral.name ?? connectedPeripheralName
        firmwareReconnectInFlight = true
        firmwareReconnectText = "正在进行第 \(attemptNumber) 次 OTA 重连"
        lastEvent = "OTA 更新中，正在重连原雷达（\(attemptNumber)/\(FirmwareReconnectPolicy.maximumAttempts)）"
        central.connect(peripheral)
        scheduleFirmwareReconnectTimeout(peripheralID: targetID, attemptNumber: attemptNumber)
    }

    private func scheduleFirmwareReconnectTimeout(peripheralID: UUID, attemptNumber: Int) {
        firmwareReconnectTimeoutTask?.cancel()
        firmwareReconnectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(FirmwareReconnectPolicy.attemptTimeout))
            guard
                !Task.isCancelled,
                let self,
                self.firmwareReconnectTrackingRequired,
                self.firmwareReconnectInFlight,
                self.firmwareReconnectTargetID == peripheralID,
                self.firmwareReconnectAttemptsStarted == attemptNumber
            else { return }

            self.firmwareReconnectTimeoutTask = nil
            self.firmwareReconnectInFlight = false
            self.firmwareReconnectAwaitingCancellation = true
            if let peripheral = self.peripherals[peripheralID] {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.clearSelectedConnection(peripheralID)
            self.firmwareReconnectText = "第 \(attemptNumber) 次 OTA 重连超时"
            self.scheduleFirmwareReconnectCancellationFallback(peripheralID: peripheralID)
        }
    }

    private func scheduleFirmwareReconnectCancellationFallback(peripheralID: UUID) {
        firmwareReconnectCancellationTask?.cancel()
        firmwareReconnectCancellationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard
                !Task.isCancelled,
                let self,
                self.firmwareReconnectAwaitingCancellation,
                self.firmwareReconnectTargetID == peripheralID
            else { return }
            self.firmwareReconnectCancellationTask = nil
            self.firmwareReconnectAwaitingCancellation = false
            self.scheduleNextFirmwareReconnectAttempt()
        }
    }

    private func finishFirmwareReconnectAttemptAndRetry(peripheralID: UUID) {
        guard firmwareReconnectTargetID == peripheralID else { return }
        firmwareReconnectTimeoutTask?.cancel()
        firmwareReconnectCancellationTask?.cancel()
        firmwareReconnectTimeoutTask = nil
        firmwareReconnectCancellationTask = nil
        firmwareReconnectInFlight = false
        firmwareReconnectAwaitingCancellation = false
        clearSelectedConnection(peripheralID)
        scheduleNextFirmwareReconnectAttempt()
    }

    private func clearSelectedConnection(_ peripheralID: UUID) {
        guard selectedPeripheralID == peripheralID else { return }
        selectedPeripheralID = nil
        ownerSessionAuthorized = false
        ownerAuthAttemptChallenge = nil
        pairingChallengeText = "未读取"
        connectedPeripheralName = "未连接"
        discoveredCharacteristics.removeAll()
        availableCharacteristicNames.removeAll()
        characteristics.removeAll()
    }

    func connect(_ candidate: BLEDeviceCandidate) {
        guard let peripheral = peripherals[candidate.peripheralID] else {
            lastEvent = "候选设备已失效，请重新扫描"
            return
        }

        stopScan()
        if firmwareReconnectTrackingRequired {
            if
                let originalTargetID = firmwareReconnectTargetID,
                originalTargetID != candidate.peripheralID
            {
                firmwareReconnectSuppressed = true
            } else {
                firmwareReconnectSuppressed = false
                captureFirmwareReconnectTarget(candidate.peripheralID)
            }
        }
        selectedPeripheralID = candidate.peripheralID
        connectedPeripheralName = candidate.name
        lastEvent = "正在连接 \(candidate.name)"
        manualDisconnectRequested = false
        central?.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func connectAuthorizedAccessory(identifier: UUID, name: String) {
        scanRequested = false
        authorizedAccessoryConnection = (identifier, name)
        ensureCentralManager()
        connectAuthorizedAccessoryIfReady()
    }

    private func connectAuthorizedAccessoryIfReady() {
        guard
            let target = authorizedAccessoryConnection,
            let central,
            central.state == .poweredOn
        else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [target.identifier]).first else {
            if !isScanning {
                resetStateForNewScan()
                scanStartedAt = Date()
                isScanning = true
                lastEvent = "系统已授权雷达，正在等待设备广播"
                central.scanForPeripherals(withServices: [radarServiceUUID])
                startScanTimeout()
            }
            return
        }

        authorizedAccessoryConnection = nil
        peripherals[target.identifier] = peripheral
        peripheral.delegate = self
        stopScan()
        selectedPeripheralID = target.identifier
        connectedPeripheralName = target.name.isEmpty ? "Capsule Radar" : target.name
        lastEvent = "正在连接 \(connectedPeripheralName)"
        manualDisconnectRequested = false
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func disconnect() {
        manualDisconnectRequested = true
        gatewayReconnectTask?.cancel()
        suspendFirmwareReconnectForManualDisconnect()
        guard
            let selectedPeripheralID,
            let peripheral = peripherals[selectedPeripheralID]
        else {
            return
        }
        central?.cancelPeripheralConnection(peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = central.state
        lastEvent = "蓝牙状态：\(stateText)"
        if central.state == .poweredOn, authorizedAccessoryConnection != nil {
            connectAuthorizedAccessoryIfReady()
            return
        }
        if central.state == .poweredOn, scanRequested {
            startScan()
            return
        }
        if central.state != .poweredOn {
            scanTimeoutTask?.cancel()
            scanTimeoutTask = nil
            scanStartedAt = nil
            isScanning = false
            firmwareReconnectRetryTask?.cancel()
            firmwareReconnectTimeoutTask?.cancel()
            firmwareReconnectCancellationTask?.cancel()
            firmwareReconnectRetryTask = nil
            firmwareReconnectTimeoutTask = nil
            firmwareReconnectCancellationTask = nil
            firmwareReconnectInFlight = false
            firmwareReconnectAwaitingCancellation = false
        } else {
            resumeFirmwareReconnectIfNeeded()
            reconnectSavedGatewayIfNeeded()
        }
    }

    private func ensureCentralManager() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestorationID]
        )
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let peripheral = restored.first else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        selectedPeripheralID = peripheral.identifier
        connectedPeripheralName = peripheral.name ?? persistedDeviceName
        defaults.set(peripheral.identifier.uuidString, forKey: Self.gatewayPeripheralKey)
        lastEvent = "系统已恢复后台雷达连接"
        if peripheral.state == .connected {
            peripheral.discoverServices([radarServiceUUID])
        }
    }

    private func reconnectSavedGatewayIfNeeded() {
        guard
            !manualDisconnectRequested,
            let central,
            central.state == .poweredOn,
            let rawID = defaults.string(forKey: Self.gatewayPeripheralKey),
            let peripheralID = UUID(uuidString: rawID),
            let peripheral = central.retrievePeripherals(withIdentifiers: [peripheralID]).first
        else { return }
        peripherals[peripheralID] = peripheral
        peripheral.delegate = self
        selectedPeripheralID = peripheralID
        connectedPeripheralName = peripheral.name ?? persistedDeviceName
        if peripheral.state == .disconnected {
            lastEvent = "正在恢复语音网关蓝牙连接"
            central.connect(
                peripheral,
                options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
            )
        } else if peripheral.state == .connected {
            peripheral.discoverServices([radarServiceUUID])
        }
    }

    private func scheduleGatewayReconnect() {
        gatewayReconnectTask?.cancel()
        gatewayReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.reconnectSavedGatewayIfNeeded()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "未命名雷达"
        if
            let target = authorizedAccessoryConnection,
            peripheral.identifier == target.identifier
        {
            authorizedAccessoryConnection = nil
            scanRequested = false
            stopScan()
            peripherals[target.identifier] = peripheral
            peripheral.delegate = self
            selectedPeripheralID = target.identifier
            connectedPeripheralName = target.name.isEmpty ? name : target.name
            lastEvent = "正在连接 \(connectedPeripheralName)"
            manualDisconnectRequested = false
            central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            return
        }
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasRadarService = serviceUUIDs.contains(radarServiceUUID)
        let likelyRadar = name.localizedCaseInsensitiveContains("CapsuleRadar")
            || name.localizedCaseInsensitiveContains("Radar")
            || name.localizedCaseInsensitiveContains("ESP")
            || hasRadarService

        guard likelyRadar else { return }

        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self

        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        let serviceHint = hasRadarService ? "雷达服务" : "名称匹配"
        let candidate = BLEDeviceCandidate(
            peripheralID: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            isConnectable: isConnectable,
            serviceHint: serviceHint,
            lastSeen: Date()
        )

        if let index = candidates.firstIndex(where: { $0.peripheralID == peripheral.identifier }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
            candidates.sort { $0.rssi > $1.rssi }
        }
        scanTimedOut = false
        lastEvent = "发现 \(name) · \(RSSI.intValue) dBm"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        manualDisconnectRequested = false
        gatewayReconnectTask?.cancel()
        defaults.set(peripheral.identifier.uuidString, forKey: Self.gatewayPeripheralKey)
        selectedPeripheralID = peripheral.identifier
        ownerSessionAuthorized = false
        ownerAuthAttemptChallenge = nil
        pairingChallengeText = "未读取"
        connectedPeripheralName = peripheral.name ?? connectedPeripheralName
        if firmwareReconnectTrackingRequired, !firmwareReconnectSuppressed {
            if firmwareReconnectTargetID == nil {
                captureFirmwareReconnectTarget(peripheral.identifier)
            }
            if firmwareReconnectTargetID == peripheral.identifier {
                firmwareReconnectRetryTask?.cancel()
                firmwareReconnectTimeoutTask?.cancel()
                firmwareReconnectCancellationTask?.cancel()
                firmwareReconnectRetryTask = nil
                firmwareReconnectTimeoutTask = nil
                firmwareReconnectCancellationTask = nil
                firmwareReconnectInFlight = false
                firmwareReconnectAwaitingCancellation = false
                firmwareReconnectText = "OTA 雷达已重连，正在恢复状态读取"
                lastEvent = "OTA 雷达已重连，正在恢复 105/108 状态"
            } else {
                lastEvent = "已连接 \(connectedPeripheralName)，正在检测雷达"
            }
        } else {
            lastEvent = "已连接 \(connectedPeripheralName)，正在检测雷达"
        }
        peripheral.discoverServices([radarServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastEvent = "连接失败：\(error?.localizedDescription ?? peripheral.identifier.uuidString)"
        if
            firmwareReconnectTrackingRequired,
            !firmwareReconnectSuppressed,
            firmwareReconnectTargetID == peripheral.identifier,
            firmwareReconnectInFlight || firmwareReconnectAwaitingCancellation
        {
            finishFirmwareReconnectAttemptAndRetry(peripheralID: peripheral.identifier)
        } else {
            clearSelectedConnection(peripheral.identifier)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        voiceGatewayAnnounced = false
        voiceGatewayText = "雷达蓝牙已断开，等待后台重连"
        clearSelectedConnection(peripheral.identifier)
        lastEvent = error.map { "已断开：\($0.localizedDescription)" } ?? "已断开 \(peripheral.name ?? "雷达")"
        if
            firmwareReconnectTrackingRequired,
            !firmwareReconnectSuppressed,
            firmwareReconnectTargetID == peripheral.identifier
        {
            firmwareReconnectInFlight = false
            firmwareReconnectAwaitingCancellation = false
            firmwareReconnectTimeoutTask?.cancel()
            firmwareReconnectCancellationTask?.cancel()
            firmwareReconnectTimeoutTask = nil
            firmwareReconnectCancellationTask = nil
            beginFirmwareReconnectWindowIfNeeded()
            scheduleNextFirmwareReconnectAttempt()
        } else if !manualDisconnectRequested {
            scheduleGatewayReconnect()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastEvent = "连接检测失败：\(error.localizedDescription)"
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            lastEvent = "未发现雷达服务"
            return
        }

        lastEvent = "正在读取雷达状态"
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            lastEvent = "雷达连接检测失败：\(error.localizedDescription)"
            return
        }

        let characteristics = service.characteristics ?? []
        discoveredCharacteristics = characteristics.map(\.uuid.uuidString).sorted()
        for characteristic in characteristics {
            guard let role = RadarBLECharacteristic.allCases.first(where: { $0.uuid == characteristic.uuid }) else {
                continue
            }
            self.characteristics[role] = characteristic

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }

        availableCharacteristicNames = RadarBLECharacteristic.allCases
            .filter { self.characteristics[$0] != nil }
            .map(\.title)

        lastEvent = discoveredCharacteristics.isEmpty
            ? "雷达连接未准备好"
            : "雷达连接已准备"
        activateVoiceGatewayIfReady()

        if
            firmwareReconnectTrackingRequired,
            !firmwareReconnectSuppressed,
            firmwareReconnectTargetID == peripheral.identifier
        {
            readDeviceStatus()
            readFirmwareStatus()
            firmwareReconnectText = "已恢复 105/108 状态读取"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastEvent = "读取雷达状态失败：\(error.localizedDescription)"
            return
        }

        guard let role = RadarBLECharacteristic.allCases.first(where: { $0.uuid == characteristic.uuid }) else {
            return
        }

        let data = characteristic.value ?? Data()
        handleCharacteristicValue(data, role: role)
    }

    private func handleCharacteristicValue(_ data: Data, role: RadarBLECharacteristic) {
        let textValue = String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined()
        switch role {
        case .pairingChallenge:
            let challenge = textValue.isEmpty ? "空挑战码" : textValue
            if challenge != pairingChallengeText {
                pairingChallengeText = challenge
                ownerSessionAuthorized = false
                ownerAuthAttemptChallenge = nil
            }
            authorizeOwnerSessionIfPossible()
        case .deviceStatus:
            deviceStatusText = textValue.isEmpty ? "空状态" : textValue
            if let parsedStatus = try? JSONDecoder().decode(RadarBLEDeviceStatus.self, from: data) {
                deviceStatus = parsedStatus
                lastDeviceStatusAt = Date()
                remember(status: parsedStatus)
            }
        case .firmwareStatus:
            firmwareStatusText = textValue.isEmpty ? "空状态" : textValue
            if let parsedStatus = try? JSONDecoder().decode(RadarBLEFirmwareStatus.self, from: data) {
                firmwareStatus = parsedStatus
                lastFirmwareStatusAt = Date()
            }
        case .voiceControl:
            voiceControlHandler?(data)
            voiceGatewayText = "雷达语音控制已更新"
        case .voiceAudioUplink:
            voiceUplinkFrames += 1
            voiceUplinkHandler?(data)
        default:
            break
        }
        if role == .deviceStatus {
            lastEvent = "雷达状态已更新"
        } else if role == .firmwareStatus {
            lastEvent = "固件更新状态已更新"
        } else {
            lastEvent = "雷达连接已确认"
        }
    }

    func completePairingResponse() -> Bool {
        let challenge = pairingChallengeText == "未读取" ? "manual" : pairingChallengeText
        let response = "mvp-response:\(challenge)"
        return writePairingResponse(response)
    }

    func writePairingResponse(_ response: String) -> Bool {
        let written = writeString(response, role: .pairingResponse)
        if written {
            deviceStatus = nil
            deviceStatusText = "等待雷达确认绑定"
            lastDeviceStatusAt = nil
        }
        return written
    }

    func writeWifiConfig(ssid: String, password: String) -> Bool {
        let payload = [
            "version": "1",
            "ssid": ssid,
            "password": password
        ]
        let written = writeJSON(payload, role: .wifiConfig)
        if written {
            deviceStatus = nil
            deviceStatusText = "等待雷达上报"
            lastDeviceStatusAt = nil
        }
        return written
    }

    func writeServerConfig(
        relayURL: String,
        roomToken: String,
        deviceToken: String,
        httpAPIURL: String = AppEnvironment.current.httpAPIBaseURL
    ) -> Bool {
        let cleanDeviceToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDeviceToken.isEmpty else {
            lastWriteEvent = "服务器配置缺少设备凭据"
            return false
        }

        let ownerAuthorizationRequired = deviceStatus?.ownerAuthRequired == 1 && deviceStatus?.paired == 1
        if deviceStatus?.server == 1 {
            configureOwnerSession(deviceToken: cleanDeviceToken)
        } else {
            // A successful v2 pairing response authorizes this connection before
            // the ESP has a token to verify a v1 owner proof. Stage the freshly
            // issued token for later reconnects without replacing that one-time
            // pairing authorization with a proof the ESP cannot verify yet.
            ownerDeviceToken = cleanDeviceToken
            ownerAuthAttemptChallenge = pairingChallengeText
        }
        if ownerAuthorizationRequired && !ownerSessionAuthorized {
            lastWriteEvent = "雷达所有者会话尚未确认，服务器配置将在授权后重试"
            return false
        }
        let payload = RadarBLEServerConfigPayload(
            relayURL: relayURL,
            httpAPIURL: httpAPIURL,
            roomToken: roomToken,
            deviceToken: cleanDeviceToken
        )
        guard let data = try? payload.encodedData() else {
            lastWriteEvent = "服务器配置内容生成失败"
            return false
        }
        let written = writeData(data, role: .serverConfig)
        if written {
            lastWriteEvent = payload.redactedLogText
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.readDeviceStatus()
            }
        }
        return written
    }

    func writeLocalLocation(_ snapshot: LocationSnapshot?) -> Bool {
        guard let snapshot else {
            lastWriteEvent = "定位无效，未写入雷达"
            return false
        }
        return writeData(snapshot.locationFrameData, role: .localLocation)
    }

    @discardableResult
    func sendVoiceControl(command: String, requestID: String? = nil) -> Bool {
        guard isVoiceGatewayReady else {
            voiceGatewayText = "语音网关未完成所有者授权"
            return false
        }
        var payload = ["command": command, "v": "1"]
        if let requestID, !requestID.isEmpty {
            payload["request_id"] = requestID
        }
        let sent = writeJSON(payload, role: .voiceControl)
        if sent {
            voiceGatewayText = "语音控制：\(command)"
        }
        return sent
    }

    func sendVoiceDownlinkFrame(_ data: Data) {
        guard !data.isEmpty else { return }
        if voiceDownlinkQueue.count >= 8 {
            voiceDownlinkQueue.removeFirst()
            voiceDroppedFrames += 1
        }
        voiceDownlinkQueue.append(data)
        flushVoiceDownlinkQueue()
    }

    private func activateVoiceGatewayIfReady() {
        guard isVoiceGatewayReady else { return }
        if !voiceGatewayAnnounced {
            voiceGatewayAnnounced = sendVoiceControl(command: "gateway_ready")
        }
        if voiceGatewayAnnounced {
            voiceGatewayText = "BLE 语音网关已就绪"
        }
        flushVoiceDownlinkQueue()
    }

    private func flushVoiceDownlinkQueue() {
        guard
            isVoiceGatewayReady,
            let selectedPeripheralID,
            let peripheral = peripherals[selectedPeripheralID],
            let characteristic = characteristics[.voiceAudioDownlink]
        else { return }
        let maximumLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        while peripheral.canSendWriteWithoutResponse, !voiceDownlinkQueue.isEmpty {
            let frame = voiceDownlinkQueue.removeFirst()
            guard frame.count <= maximumLength else {
                voiceDroppedFrames += 1
                voiceGatewayText = "BLE MTU 过小（\(frame.count)/\(maximumLength)）"
                continue
            }
            peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
            voiceDownlinkFrames += 1
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushVoiceDownlinkQueue()
    }

    func writeFirmwareStart(_ release: VerifiedFirmwareManifest) -> Bool {
        guard firmwareOwnerSessionReady else {
            authorizeOwnerSessionIfPossible()
            lastWriteEvent = "雷达所有者会话尚未确认，请保持连接后重试"
            return false
        }
        do {
            try FirmwareManifestVerifier().verify(release.manifest)
            try FirmwareArtifactURLPolicy.validate(
                release.artifactURL,
                baseURLString: AppEnvironment.current.httpAPIBaseURL,
                requireHTTPS: AppEnvironment.current.isProduction
            )
            let data = try release.manifest.compactControlData(artifactURL: release.artifactURL)
            return writeData(data, role: .firmwareControl)
        } catch {
            lastWriteEvent = error.localizedDescription
            return false
        }
    }

    func writeFirmwareAction(_ action: String) -> Bool {
        guard firmwareOwnerSessionReady else {
            authorizeOwnerSessionIfPossible()
            lastWriteEvent = "雷达所有者会话尚未确认，请保持连接后重试"
            return false
        }
        guard ["status", "cancel"].contains(action) else {
            lastWriteEvent = "不支持的固件控制动作"
            return false
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["v": 1, "a": action],
            options: [.sortedKeys]
        ) else {
            lastWriteEvent = "固件控制内容生成失败"
            return false
        }
        return writeData(data, role: .firmwareControl)
    }

    private func writeString(_ string: String, role: RadarBLECharacteristic) -> Bool {
        writeData(Data(string.utf8), role: role)
    }

    private func writeJSON(_ payload: [String: String], role: RadarBLECharacteristic) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            lastWriteEvent = "写入内容生成失败"
            return false
        }
        return writeData(data, role: role)
    }

    private func writeData(_ data: Data, role: RadarBLECharacteristic) -> Bool {
        if role == .firmwareControl {
            firmwareControlWriteError = nil
        }
        guard
            let selectedPeripheralID,
            let peripheral = peripherals[selectedPeripheralID]
        else {
            lastWriteEvent = "雷达连接未准备好 · 请重新扫描并连接雷达"
            return false
        }

        guard let characteristic = characteristics[role] else {
            refreshCharacteristics()
            lastWriteEvent = "雷达连接未准备好"
            return false
        }

        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
            lastWriteEvent = "当前雷达不支持写入"
            return false
        }

        let maximumLength = peripheral.maximumWriteValueLength(for: writeType)
        guard data.count <= maximumLength else {
            lastWriteEvent = "固件控制内容过长（\(data.count)/\(maximumLength) 字节）"
            return false
        }

        peripheral.writeValue(data, for: characteristic, type: writeType)
        lastWriteEvent = "正在写入雷达"
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let role = RadarBLECharacteristic.allCases.first(where: { $0.uuid == characteristic.uuid }) else {
            return
        }

        handleCharacteristicWriteResult(role: role, error: error?.localizedDescription)
    }

    private func handleCharacteristicWriteResult(role: RadarBLECharacteristic, error: String?) {
        if let error {
            lastWriteEvent = "写入雷达失败：\(error)"
            if role == .firmwareControl {
                firmwareControlWriteError = lastWriteEvent
            }
        } else {
            lastWriteEvent = "雷达写入已确认"
            rememberConfirmedWrite(role)
            if role == .pairingResponse || role == .serverConfig {
                readDeviceStatus()
            } else if role == .firmwareControl {
                readFirmwareStatus()
            }
        }
    }

    private func remember(status: RadarBLEDeviceStatus) {
        if status.ownerAuthRequired == 1 {
            ownerSessionAuthorized = status.ownerAuth == 1
            if !ownerSessionAuthorized {
                authorizeOwnerSessionIfPossible()
            }
        }
        persistedPaired = status.paired == 1
        defaults.set(persistedPaired, forKey: Self.persistedPairedKey)
        persistedServerConfigured = status.server == 1
        defaults.set(persistedServerConfigured, forKey: Self.persistedServerConfiguredKey)
        if !status.name.isEmpty {
            persistedDeviceName = status.name
            defaults.set(status.name, forKey: Self.persistedDeviceNameKey)
        }
        activateVoiceGatewayIfReady()
    }

    private func rememberConfirmedWrite(_ role: RadarBLECharacteristic) {
        switch role {
        case .pairingResponse:
            persistedPaired = true
            defaults.set(true, forKey: Self.persistedPairedKey)
        case .serverConfig:
            persistedServerConfigured = true
            defaults.set(true, forKey: Self.persistedServerConfiguredKey)
        default:
            break
        }
    }
}
