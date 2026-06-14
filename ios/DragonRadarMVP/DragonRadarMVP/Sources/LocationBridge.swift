import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationBridge: NSObject, @preconcurrency CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var uiTestingForcesLocationDenied = false

    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization
    var isSharing = false
    var isUserPaused = false
    var latestLocation: CLLocation?
    var lastError: String?
    var lastUpdateText = "未开始"
    var lastAcceptedLocationAt: Date?

    override init() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        configureUITestingStateIfNeeded()
    }

    var permissionText: String {
        switch authorizationStatus {
        case .authorizedAlways:
            "始终允许"
        case .authorizedWhenInUse:
            "使用期间"
        case .denied, .restricted:
            "不可用"
        case .notDetermined:
            "待授权"
        @unknown default:
            "未知"
        }
    }

    var precisionText: String {
        guard isAuthorized else { return "未授权" }
        switch accuracyAuthorization {
        case .fullAccuracy:
            return "精确定位"
        case .reducedAccuracy:
            return "大致定位"
        @unknown default:
            return "未知精度"
        }
    }

    var backgroundText: String {
        guard Self.backgroundLocationModeEnabled else { return "后台能力未启用" }
        switch authorizationStatus {
        case .authorizedAlways:
            return "后台定位可用"
        case .authorizedWhenInUse:
            return "仅前台，需始终允许"
        case .notDetermined:
            return "等待授权"
        case .denied, .restricted:
            return "后台不可用"
        @unknown default:
            return "状态未知"
        }
    }

    var uploadReadinessText: String {
        if isUserPaused { return "用户已暂停" }
        if !isSharing { return "未共享" }
        switch authorizationStatus {
        case .authorizedAlways:
            break
        case .authorizedWhenInUse:
            return accuracyAuthorization == .reducedAccuracy ? "仅前台大致定位" : "仅前台上传"
        case .notDetermined:
            return "等待定位授权"
        case .denied, .restricted:
            return "定位权限不可用"
        @unknown default:
            return "定位状态未知"
        }
        guard latestLocation != nil else { return "等待定位" }
        return accuracyAuthorization == .reducedAccuracy ? "可上传，大致定位" : "可上传"
    }

    var locationAgeText: String {
        guard let lastAcceptedLocationAt else { return "无定位" }
        return Self.relativeText(since: lastAcceptedLocationAt)
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var isReducedAccuracy: Bool {
        isAuthorized && accuracyAuthorization == .reducedAccuracy
    }

    var sharingText: String {
        guard !isUserPaused else { return "用户已暂停" }
        guard isSharing else { return "未共享" }
        guard latestLocation != nil else { return "等待定位" }
        return "正在共享"
    }

    var coordinateText: String {
        guard let latestLocation else { return "无坐标" }
        return String(
            format: "%.5f, %.5f",
            latestLocation.coordinate.latitude,
            latestLocation.coordinate.longitude
        )
    }

    var accuracyText: String {
        guard let latestLocation else { return "无精度" }
        return String(format: "±%.0fm", latestLocation.horizontalAccuracy)
    }

    var snapshot: LocationSnapshot? {
        guard let latestLocation else { return nil }
        return LocationSnapshot(
            latE7: Int32((latestLocation.coordinate.latitude * 10_000_000).rounded()),
            lonE7: Int32((latestLocation.coordinate.longitude * 10_000_000).rounded()),
            horizontalAccuracyCM: UInt16(clamping: Int((latestLocation.horizontalAccuracy * 100).rounded())),
            speedCMS: UInt16(clamping: Int((max(0, latestLocation.speed) * 100).rounded())),
            courseDeg100: UInt16(clamping: Int((max(0, latestLocation.course) * 100).rounded())),
            timestamp: latestLocation.timestamp
        )
    }

    func requestAccess() {
        #if DEBUG
        guard !uiTestingForcesLocationDenied else {
            applyUITestingLocationDeniedState()
            return
        }
        #endif
        manager.requestWhenInUseAuthorization()
    }

    func startSharing() {
        #if DEBUG
        guard !uiTestingForcesLocationDenied else {
            applyUITestingLocationDeniedState()
            return
        }
        #endif
        isUserPaused = false
        isSharing = true
        lastError = nil

        switch authorizationStatus {
        case .authorizedAlways:
            startLocationUpdates()
            lastUpdateText = "等待定位"
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            startLocationUpdates()
            lastUpdateText = "等待定位"
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            lastUpdateText = "等待授权"
        case .denied, .restricted:
            lastError = "定位权限不可用"
            lastUpdateText = "权限不可用"
        @unknown default:
            lastError = "定位状态未知"
            lastUpdateText = "状态未知"
        }
    }

    func stopSharing(markUserPaused: Bool = false) {
        if markUserPaused {
            isUserPaused = true
        }
        isSharing = false
        manager.stopUpdatingLocation()
        lastUpdateText = "已暂停"
    }

    func pauseSharingByUser() {
        stopSharing(markUserPaused: true)
    }

    func toggleSharing() {
        if isSharing {
            pauseSharingByUser()
        } else {
            startSharing()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        #if DEBUG
        guard !uiTestingForcesLocationDenied else {
            applyUITestingLocationDeniedState()
            return
        }
        #endif
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if isSharing {
            switch authorizationStatus {
            case .authorizedAlways:
                startLocationUpdates()
            case .authorizedWhenInUse:
                manager.requestAlwaysAuthorization()
                startLocationUpdates()
            case .denied, .restricted:
                lastError = "定位权限不可用"
                lastUpdateText = "权限不可用"
            default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        if shouldReject(location) {
            latestLocation = nil
            lastError = "检测到模拟定位，未上传"
            lastUpdateText = "模拟定位已拦截"
            return
        }
        latestLocation = location
        lastAcceptedLocationAt = Date()
        accuracyAuthorization = manager.accuracyAuthorization
        lastError = nil
        lastUpdateText = "刚刚"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
        lastUpdateText = "定位失败"
    }

    private func startLocationUpdates() {
        manager.startUpdatingLocation()
    }

    #if DEBUG
    private func configureUITestingStateIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("DRAGON_RADAR_UI_TESTING_LOCATION_DENIED") else { return }

        uiTestingForcesLocationDenied = true
        applyUITestingLocationDeniedState()
    }

    private func applyUITestingLocationDeniedState() {
        authorizationStatus = .denied
        accuracyAuthorization = .fullAccuracy
        isSharing = true
        isUserPaused = false
        latestLocation = nil
        lastAcceptedLocationAt = nil
        lastError = "定位权限不可用"
        lastUpdateText = "权限不可用"
    }
    #else
    private func configureUITestingStateIfNeeded() {}
    #endif

    private static var backgroundLocationModeEnabled: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") == true
    }

    private static func relativeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds)秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        return "\(hours)小时前"
    }

    private func shouldReject(_ location: CLLocation) -> Bool {
        if location.sourceInformation?.isSimulatedBySoftware == true {
            return true
        }

        // Xcode/CoreLocation frequently uses this San Francisco coordinate as a
        // simulated default. Do not let it become the room's authoritative GPS.
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        return abs(lat - 37.785834) < 0.00002 && abs(lon - (-122.406417)) < 0.00002
    }
}
