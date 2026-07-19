import CoreLocation
import Foundation
import Observation

enum PhoneHeadingReference: String, Hashable {
    case trueNorth = "true_north"
    case magneticNorth = "magnetic_north"

    var displayText: String {
        switch self {
        case .trueNorth:
            return "真北"
        case .magneticNorth:
            return "磁北"
        }
    }
}

enum PhoneHeadingQuality: String, Hashable {
    case good
    case limited
    case stale
    case unavailable

    var displayText: String {
        switch self {
        case .good:
            return "可用"
        case .limited:
            return "仅供参考"
        case .stale:
            return "已过期"
        case .unavailable:
            return "不可用"
        }
    }
}

enum LocationUploadPolicy {
    static let maximumLocationClockSkew: TimeInterval = 5
    static let maximumMotionSampleAge: TimeInterval = 20
    static let missingSampleRequestInterval: TimeInterval = 10

    static func transmissionTimestamp(
        sampleTimestamp: Date,
        now: Date,
        isSharing: Bool,
        isAuthorized: Bool
    ) -> Date? {
        guard isSharing, isAuthorized else { return nil }
        guard now.timeIntervalSince(sampleTimestamp) >= -maximumLocationClockSkew else {
            return nil
        }

        // Core Location honors the distance filter and may not emit another
        // sample while a phone is stationary. The active runtime still needs
        // to renew that last trusted position before Relay's 30-second TTL.
        return now
    }

    static func motionSampleIsFresh(sampleTimestamp: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(sampleTimestamp)
        return age >= -maximumLocationClockSkew && age <= maximumMotionSampleAge
    }

    static func shouldRequestMissingSample(
        hasLocation: Bool,
        isSharing: Bool,
        isAuthorized: Bool,
        requestPending: Bool,
        lastRequestedAt: Date,
        now: Date
    ) -> Bool {
        guard !hasLocation, isSharing, isAuthorized, !requestPending else {
            return false
        }
        return now.timeIntervalSince(lastRequestedAt) >= missingSampleRequestInterval
    }
}

struct PhoneHeadingSnapshot: Hashable {
    static let maximumFreshAge: TimeInterval = 5
    static let maximumGoodAccuracyDegrees = 20.0

    var degrees: Double
    var accuracyDegrees: Double
    var reference: PhoneHeadingReference
    var timestamp: Date

    var degreesHundredths: UInt16? {
        Self.encodeDegrees(degrees)
    }

    var accuracyHundredths: UInt16? {
        guard accuracyDegrees.isFinite, accuracyDegrees >= 0 else { return nil }
        return UInt16(clamping: Int((accuracyDegrees * 100).rounded()))
    }

    func quality(at now: Date = .now) -> PhoneHeadingQuality {
        guard degreesHundredths != nil, accuracyDegrees.isFinite, accuracyDegrees >= 0 else {
            return .unavailable
        }
        guard now.timeIntervalSince(timestamp) <= Self.maximumFreshAge else {
            return .stale
        }
        guard reference == .trueNorth, accuracyDegrees <= Self.maximumGoodAccuracyDegrees else {
            return .limited
        }
        return .good
    }

    private static func encodeDegrees(_ value: Double) -> UInt16? {
        guard value.isFinite, value >= 0 else { return nil }
        let normalized = value.truncatingRemainder(dividingBy: 360)
        let roundedHundredths = Int((normalized * 100).rounded()) % 36_000
        return UInt16(roundedHundredths)
    }
}

@MainActor
@Observable
final class LocationBridge: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let sharedLocationDesiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyNearestTenMeters
    static let sharedLocationDistanceFilter: CLLocationDistance = 10

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let refreshManager = CLLocationManager()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var uiTestingForcesLocationDenied = false
    @ObservationIgnored private var locationRefreshPending = false
    @ObservationIgnored private var lastLocationRefreshRequestedAt = Date.distantPast
    private static let userPausedKey = "dragonRadar.location.userPaused"
    private static let backgroundAccessRequestedKey = "dragonRadar.location.backgroundAccessRequested"

    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization
    var isSharing = false
    var isUserPaused: Bool
    var backgroundAccessRequested: Bool
    var latestLocation: CLLocation?
    var latestPhoneHeading: PhoneHeadingSnapshot?
    var lastError: String?
    var lastUpdateText = "未开始"
    var lastAcceptedLocationAt: Date?

    override init() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        isUserPaused = (defaults.object(forKey: Self.userPausedKey) as? Bool) ?? true
        backgroundAccessRequested = defaults.bool(forKey: Self.backgroundAccessRequestedKey)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = Self.sharedLocationDesiredAccuracy
        manager.distanceFilter = Self.sharedLocationDistanceFilter
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
        manager.showsBackgroundLocationIndicator = true
        refreshManager.delegate = self
        refreshManager.desiredAccuracy = Self.sharedLocationDesiredAccuracy
        refreshManager.distanceFilter = kCLDistanceFilterNone
        configureUITestingStateIfNeeded()
        print(
            "DragonRadar location bridge initialized "
                + "authorized=\(isAuthorized ? 1 : 0) "
                + "permission=\(permissionText) "
                + "services=\(CLLocationManager.locationServicesEnabled() ? 1 : 0) "
                + "userPaused=\(isUserPaused ? 1 : 0)"
        )
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
            return backgroundAccessRequested ? "等待始终允许" : "仅前台，可手动开启后台"
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

    var phoneHeadingQuality: PhoneHeadingQuality {
        latestPhoneHeading?.quality() ?? .unavailable
    }

    var phoneHeadingReferenceText: String {
        latestPhoneHeading?.reference.displayText ?? "无方向"
    }

    var phoneHeadingAccuracyText: String {
        guard let accuracy = latestPhoneHeading?.accuracyDegrees, accuracy >= 0 else {
            return "无精度"
        }
        return String(format: "±%.0f°", accuracy)
    }

    var phoneHeadingAgeText: String {
        guard let timestamp = latestPhoneHeading?.timestamp else { return "无方向" }
        return Self.relativeText(since: timestamp)
    }

    var courseText: String {
        guard let course = latestLocation?.course, course.isFinite, course >= 0 else {
            return "无行进航向"
        }
        return String(format: "%.0f°", course)
    }

    var snapshot: LocationSnapshot? {
        guard let latestLocation = latestLocation ?? manager.location ?? refreshManager.location else {
            return nil
        }
        guard !shouldReject(latestLocation) else { return nil }
        let now = Date()
        guard let transmissionTimestamp = LocationUploadPolicy.transmissionTimestamp(
            sampleTimestamp: latestLocation.timestamp,
            now: now,
            isSharing: isSharing,
            isAuthorized: isAuthorized
        ) else {
            return nil
        }
        let motionSampleIsFresh = LocationUploadPolicy.motionSampleIsFresh(
            sampleTimestamp: latestLocation.timestamp,
            now: now
        )
        let courseDeg100: UInt16?
        if motionSampleIsFresh, latestLocation.course.isFinite, latestLocation.course >= 0 {
            courseDeg100 = UInt16(clamping: Int((latestLocation.course * 100).rounded()))
        } else {
            courseDeg100 = nil
        }
        return LocationSnapshot(
            latE7: Int32((latestLocation.coordinate.latitude * 10_000_000).rounded()),
            lonE7: Int32((latestLocation.coordinate.longitude * 10_000_000).rounded()),
            horizontalAccuracyCM: UInt16(clamping: Int((latestLocation.horizontalAccuracy * 100).rounded())),
            speedCMS: motionSampleIsFresh
                ? UInt16(clamping: Int((max(0, latestLocation.speed) * 100).rounded()))
                : 0,
            courseDeg100: courseDeg100,
            phoneHeading: latestPhoneHeading,
            isReducedAccuracy: isReducedAccuracy,
            timestamp: transmissionTimestamp
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

    func requestBackgroundAccess() {
        backgroundAccessRequested = true
        defaults.set(true, forKey: Self.backgroundAccessRequestedKey)
        switch authorizationStatus {
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            lastUpdateText = "后台定位已允许"
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            lastUpdateText = "等待始终允许"
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            lastUpdateText = "请先允许使用期间定位，再开启后台共享"
        case .denied, .restricted:
            lastError = "请在系统设置中允许始终定位"
        @unknown default:
            lastError = "定位状态未知"
        }
    }

    func startSharing() {
        #if DEBUG
        guard !uiTestingForcesLocationDenied else {
            applyUITestingLocationDeniedState()
            return
        }
        #endif
        isUserPaused = false
        defaults.set(false, forKey: Self.userPausedKey)
        isSharing = true
        lastError = nil
        print(
            "DragonRadar location sharing start "
                + "authorized=\(isAuthorized ? 1 : 0) "
                + "permission=\(permissionText) "
                + "services=\(CLLocationManager.locationServicesEnabled() ? 1 : 0)"
        )

        switch authorizationStatus {
        case .authorizedAlways:
            startLocationUpdates()
            requestLocationRefreshIfNeeded()
            lastUpdateText = "等待定位"
        case .authorizedWhenInUse:
            startLocationUpdates()
            requestLocationRefreshIfNeeded()
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

    func requestLocationRefreshIfNeeded(now: Date = .now) {
        let hasLocation = latestLocation != nil || manager.location != nil || refreshManager.location != nil
        guard LocationUploadPolicy.shouldRequestMissingSample(
            hasLocation: hasLocation,
            isSharing: isSharing,
            isAuthorized: isAuthorized,
            requestPending: locationRefreshPending,
            lastRequestedAt: lastLocationRefreshRequestedAt,
            now: now
        ) else {
            return
        }

        locationRefreshPending = true
        lastLocationRefreshRequestedAt = now
        print(
            "DragonRadar location refresh requested "
                + "authorized=\(isAuthorized ? 1 : 0) "
                + "permission=\(permissionText)"
        )
        refreshManager.requestLocation()
        lastUpdateText = "正在获取定位"
    }

    func stopSharing(markUserPaused: Bool = false) {
        if markUserPaused {
            isUserPaused = true
            defaults.set(true, forKey: Self.userPausedKey)
        }
        isSharing = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
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
        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
        print(
            "DragonRadar location authorization changed "
                + "source=\(manager === refreshManager ? "refresh" : "continuous") "
                + "authorized=\(isAuthorized ? 1 : 0) "
                + "permission=\(permissionText) "
                + "services=\(CLLocationManager.locationServicesEnabled() ? 1 : 0)"
        )
        if isSharing {
            switch authorizationStatus {
            case .authorizedAlways:
                startLocationUpdates()
            case .authorizedWhenInUse:
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
        if manager === refreshManager {
            locationRefreshPending = false
        }
        guard let location = locations.last else { return }
        print(
            "DragonRadar location sample received "
                + "source=\(manager === refreshManager ? "refresh" : "continuous") "
                + "accuracy_m=\(Int(location.horizontalAccuracy.rounded())) "
                + "age_s=\(Int(max(0, Date().timeIntervalSince(location.timestamp)).rounded()))"
        )
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

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let reference: PhoneHeadingReference
        let degrees: Double
        if newHeading.trueHeading.isFinite, newHeading.trueHeading >= 0 {
            reference = .trueNorth
            degrees = newHeading.trueHeading
        } else {
            reference = .magneticNorth
            degrees = newHeading.magneticHeading
        }
        latestPhoneHeading = PhoneHeadingSnapshot(
            degrees: degrees,
            accuracyDegrees: newHeading.headingAccuracy,
            reference: reference,
            timestamp: newHeading.timestamp
        )
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if manager === refreshManager {
            locationRefreshPending = false
        }
        let nsError = error as NSError
        print(
            "DragonRadar location failed "
                + "source=\(manager === refreshManager ? "refresh" : "continuous") "
                + "domain=\(nsError.domain) "
                + "code=\(nsError.code)"
        )
        lastError = error.localizedDescription
        lastUpdateText = "定位失败"
    }

    private func startLocationUpdates() {
        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
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
        latestPhoneHeading = nil
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
