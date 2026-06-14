import CoreBluetooth
import Foundation
import Observation

enum RadarBLECharacteristic: String, CaseIterable, Identifiable {
    case pairingChallenge = "pairing_challenge"
    case pairingResponse = "pairing_response"
    case wifiConfig = "wifi_config"
    case localLocation = "local_location"
    case deviceStatus = "device_status"
    case serverConfig = "server_config"

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
        }
    }

    var title: String {
        rawValue
    }
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

    enum CodingKeys: String, CodingKey {
        case v
        case name
        case ble
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
    }

    var bleText: String { ble == 1 ? "BLE 配置通道已连接" : "BLE 配置通道未连接" }
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
}

@MainActor
@Observable
final class BLEDeviceBridge: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristics: [RadarBLECharacteristic: CBCharacteristic] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var scanTimeoutTask: Task<Void, Never>?

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
    var scanTimedOut = false
    private var scanStartedAt: Date?

    override init() {
        super.init()
        persistedPaired = defaults.bool(forKey: Self.persistedPairedKey)
        persistedServerConfigured = defaults.bool(forKey: Self.persistedServerConfiguredKey)
        persistedDeviceName = defaults.string(forKey: Self.persistedDeviceNameKey) ?? "未注册"
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private static let persistedPairedKey = "dragonRadar.esp.paired"
    private static let persistedServerConfiguredKey = "dragonRadar.esp.serverConfigured"
    private static let persistedDeviceNameKey = "dragonRadar.esp.deviceName"

    private static func append(_ value: String, to history: [String]) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return Array(([ "\(stamp) \(trimmed)" ] + history).prefix(20))
    }

    var isBLEConnected: Bool {
        selectedPeripheralID != nil
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
        guard let central else { return }
        guard central.state == .poweredOn else {
            lastEvent = "蓝牙不可用：\(stateText)"
            return
        }

        candidates.removeAll()
        discoveredCharacteristics.removeAll()
        availableCharacteristicNames.removeAll()
        characteristics.removeAll()
        deviceStatus = nil
        deviceStatusText = "未读取"
        pairingChallengeText = "未读取"
        scanTimedOut = false
        scanStartedAt = Date()
        isScanning = true
        lastEvent = "正在查找附近的雷达"
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        startScanTimeout()
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

    func connect(_ candidate: BLEDeviceCandidate) {
        guard let peripheral = peripherals[candidate.peripheralID] else {
            lastEvent = "候选设备已失效，请重新扫描"
            return
        }

        stopScan()
        selectedPeripheralID = candidate.peripheralID
        connectedPeripheralName = candidate.name
        lastEvent = "正在连接 \(candidate.name)"
        central?.connect(peripheral)
    }

    func disconnect() {
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
        if central.state != .poweredOn {
            scanTimeoutTask?.cancel()
            scanTimeoutTask = nil
            scanStartedAt = nil
            isScanning = false
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
        selectedPeripheralID = peripheral.identifier
        connectedPeripheralName = peripheral.name ?? connectedPeripheralName
        lastEvent = "已连接 \(connectedPeripheralName)，正在检测雷达"
        peripheral.discoverServices([radarServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastEvent = "连接失败：\(error?.localizedDescription ?? peripheral.identifier.uuidString)"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if selectedPeripheralID == peripheral.identifier {
            selectedPeripheralID = nil
            connectedPeripheralName = "未连接"
            discoveredCharacteristics.removeAll()
            availableCharacteristicNames.removeAll()
            characteristics.removeAll()
        }
        lastEvent = error.map { "已断开：\($0.localizedDescription)" } ?? "已断开 \(peripheral.name ?? "雷达")"
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
        let textValue = String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined()
        switch role {
        case .pairingChallenge:
            pairingChallengeText = textValue.isEmpty ? "空挑战码" : textValue
        case .deviceStatus:
            deviceStatusText = textValue.isEmpty ? "空状态" : textValue
            if let parsedStatus = try? JSONDecoder().decode(RadarBLEDeviceStatus.self, from: data) {
                deviceStatus = parsedStatus
                lastDeviceStatusAt = Date()
                remember(status: parsedStatus)
            }
        default:
            break
        }
        lastEvent = role == .deviceStatus ? "雷达状态已更新" : "雷达连接已确认"
    }

    func completePairingResponse() -> Bool {
        let challenge = pairingChallengeText == "未读取" ? "manual" : pairingChallengeText
        let response = "mvp-response:\(challenge)"
        return writePairingResponse(response)
    }

    func writePairingResponse(_ response: String) -> Bool {
        writeString(response, role: .pairingResponse)
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

    func writeServerConfig(relayURL: String, roomToken: String, deviceToken: String) -> Bool {
        let payload = [
            "version": "1",
            "relay_url": relayURL,
            "room_token": roomToken,
            "device_token": deviceToken
        ]
        return writeJSON(payload, role: .serverConfig)
    }

    func writeLocalLocation(_ snapshot: LocationSnapshot?) -> Bool {
        guard let snapshot else {
            lastWriteEvent = "定位无效，未写入雷达"
            return false
        }
        return writeData(snapshot.locationFrameData, role: .localLocation)
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

        peripheral.writeValue(data, for: characteristic, type: writeType)
        lastWriteEvent = "正在写入雷达"
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let role = RadarBLECharacteristic.allCases.first(where: { $0.uuid == characteristic.uuid }) else {
            return
        }

        if let error {
            lastWriteEvent = "写入雷达失败：\(error.localizedDescription)"
        } else {
            lastWriteEvent = "雷达写入已确认"
            rememberConfirmedWrite(role)
        }
    }

    private func remember(status: RadarBLEDeviceStatus) {
        if status.paired == 1 {
            persistedPaired = true
            defaults.set(true, forKey: Self.persistedPairedKey)
        }
        if status.server == 1 {
            persistedServerConfigured = true
            defaults.set(true, forKey: Self.persistedServerConfiguredKey)
        }
        if !status.name.isEmpty {
            persistedDeviceName = status.name
            defaults.set(status.name, forKey: Self.persistedDeviceNameKey)
        }
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
