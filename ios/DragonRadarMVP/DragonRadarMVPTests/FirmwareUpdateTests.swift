import CryptoKit
import XCTest
@testable import DragonRadarMVP

final class FirmwareUpdateTests: XCTestCase {
    func testEmbeddedOTAPublicKeyIsValidP256PEM() {
        XCTAssertNoThrow(
            try P256.Signing.PublicKey(pemRepresentation: FirmwareManifestVerifier.embeddedPublicKeyPEM)
        )
    }

    func testCanonicalPayloadMatchesRelayContractWithoutTrailingNewline() {
        let manifest = makeManifest(signature: "AA==")

        XCTAssertEqual(
            manifest.canonicalString,
            """
            dragon-radar-ota-v1
            schema=1
            product=dragon-radar
            hardware=esp32-s3-touch-amoled-1.75c
            version=1.1.0
            build=2
            minimum_version=1.0.0
            security_counter=2
            size=3070336
            sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """
        )
        XCTAssertFalse(manifest.canonicalString.hasSuffix("\n"))
        XCTAssertEqual(manifest.canonicalData, Data(manifest.canonicalString.utf8))
    }

    func testP256DERSignatureIsAcceptedAndTamperingIsRejected() throws {
        let privateKey = P256.Signing.PrivateKey()
        var manifest = makeManifest(signature: "")
        let signature = try privateKey.signature(for: manifest.canonicalData)
        manifest.signature = signature.derRepresentation.base64EncodedString()
        let verifier = FirmwareManifestVerifier(publicKeyPEM: privateKey.publicKey.pemRepresentation)

        XCTAssertNoThrow(try verifier.verify(manifest))

        manifest.version = "1.1.1"
        XCTAssertThrowsError(try verifier.verify(manifest)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidSignature)
        }
    }

    func testVerifierRejectsAlgorithmKeyAndUppercaseDigest() throws {
        let privateKey = P256.Signing.PrivateKey()
        var manifest = makeManifest(signature: "")
        manifest.signature = try privateKey.signature(for: manifest.canonicalData).derRepresentation.base64EncodedString()
        let verifier = FirmwareManifestVerifier(publicKeyPEM: privateKey.publicKey.pemRepresentation)

        var wrongAlgorithm = manifest
        wrongAlgorithm.signatureAlgorithm = "rsa-sha256"
        XCTAssertThrowsError(try verifier.verify(wrongAlgorithm)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .unsupportedAlgorithm)
        }

        var wrongKey = manifest
        wrongKey.keyID = "unknown"
        XCTAssertThrowsError(try verifier.verify(wrongKey)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .unsupportedKey)
        }

        var uppercaseDigest = manifest
        uppercaseDigest.sha256 = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try verifier.verify(uppercaseDigest)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidField("sha256"))
        }

        var zeroSecurityCounter = manifest
        zeroSecurityCounter.securityCounter = 0
        XCTAssertThrowsError(try verifier.verify(zeroSecurityCounter)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidField("security_counter"))
        }

        var oversizedBuild = manifest
        oversizedBuild.build = Int(UInt32.max) + 1
        XCTAssertThrowsError(try verifier.verify(oversizedBuild)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidField("build"))
        }

        var oversizedSecurityCounter = manifest
        oversizedSecurityCounter.securityCounter = Int(UInt32.max) + 1
        XCTAssertThrowsError(try verifier.verify(oversizedSecurityCounter)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidField("security_counter"))
        }
    }

    func testSemanticVersionOrdering() throws {
        let previous = try XCTUnwrap(FirmwareSemanticVersion("1.2.2"))
        let release = try XCTUnwrap(FirmwareSemanticVersion("1.2.3"))
        let next = try XCTUnwrap(FirmwareSemanticVersion("1.2.4"))

        XCTAssertLessThan(previous, release)
        XCTAssertLessThan(release, next)
        XCTAssertNil(FirmwareSemanticVersion("R1.0"))
        XCTAssertNil(FirmwareSemanticVersion("1.2"))
        XCTAssertNil(FirmwareSemanticVersion("1.2.3-beta"))
        XCTAssertNil(FirmwareSemanticVersion("1.2.3+build.9"))
        XCTAssertNil(FirmwareSemanticVersion("4294967296.1.0"))
    }

    func testServerConfigPayloadCarriesHTTPAPIURLAndRedactsTokensFromLogs() throws {
        let roomToken = "ROOM-SECRET-123"
        let deviceToken = "DEVICE-SECRET-456"
        let payload = RadarBLEServerConfigPayload(
            relayURL: "wss://relay.example/v1/radar/device/ws",
            httpAPIURL: "https://api.example/base",
            roomToken: roomToken,
            deviceToken: deviceToken
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.encodedData()) as? [String: String])

        XCTAssertEqual(object["version"], "1")
        XCTAssertEqual(object["relay_url"], "wss://relay.example/v1/radar/device/ws")
        XCTAssertEqual(object["http_api_url"], "https://api.example/base")
        XCTAssertEqual(object["room_token"], roomToken)
        XCTAssertEqual(object["device_token"], deviceToken)
        XCTAssertFalse(payload.redactedLogText.contains(roomToken))
        XCTAssertFalse(payload.redactedLogText.contains(deviceToken))
        XCTAssertTrue(payload.redactedLogText.contains("敏感凭证已省略"))
    }

    func testCompactFirmwareStatusDecoding() throws {
        let data = Data(#"{"v":1,"fw":"1.0.0","b":1,"h":"esp32-s3-touch-amoled-1.75c","s":"downloading","p":42,"rx":1284505,"z":3070336,"tv":"1.1.0","tb":2,"e":""}"#.utf8)
        let status = try JSONDecoder().decode(RadarBLEFirmwareStatus.self, from: data)

        XCTAssertEqual(status.protocolVersion, 1)
        XCTAssertEqual(status.firmwareVersion, "1.0.0")
        XCTAssertEqual(status.build, 1)
        XCTAssertEqual(status.stage, "downloading")
        XCTAssertEqual(status.progress, 42)
        XCTAssertEqual(status.receivedBytes, 1_284_505)
        XCTAssertEqual(status.totalBytes, 3_070_336)
        XCTAssertEqual(status.targetVersion, "1.1.0")
        XCTAssertEqual(status.targetBuild, 2)
    }

    func testCompactDeviceStatusPreservesOwnerAndOTAFieldsWithinBLELimit() throws {
        let data = Data(#"{"v":1,"fw":"1.0.1","build":3,"hw":"esp32-s3-touch-amoled-1.75c","ota":1,"security_counter":3,"ota_origin":1,"name":"CapsuleRadar-F2A0","ble":1,"ble_secure":1,"paired":1,"owner_auth_required":1,"owner_auth":1,"wifi":"connected","rssi":-57,"ip":"172.20.10.2","server":1,"loc":1,"battery":{"present":true,"percent":84,"voltage_mv":4012,"charging":true,"discharging":false,"low":false},"last":"status_event_truncated"}"#.utf8)

        XCTAssertLessThanOrEqual(data.count, 512)
        let status = try JSONDecoder().decode(RadarBLEDeviceStatus.self, from: data)

        XCTAssertNil(status.relay)
        XCTAssertEqual(status.firmwareVersion, "1.0.1")
        XCTAssertEqual(status.firmwareBuild, 3)
        XCTAssertEqual(status.securityCounter, 3)
        XCTAssertEqual(status.otaOrigin, 1)
        XCTAssertEqual(status.bleSecure, 1)
        XCTAssertEqual(status.bleSecurityText, "系统加密配对已完成")
        XCTAssertEqual(status.ownerAuthRequired, 1)
        XCTAssertEqual(status.ownerAuth, 1)
        XCTAssertEqual(status.last, "status_event_truncated")
        XCTAssertTrue(status.supportsOTA)
        XCTAssertTrue(status.isOTAProvisioningReady)
        XCTAssertTrue(status.isOTAOriginConfirmed)
    }

    func testVerboseFirmwareStatusDecodingAndProgressClamp() throws {
        let data = Data(#"{"firmware_version":"1.1.0","build":2,"hardware":"esp32-s3-touch-amoled-1.75c","stage":"success","progress":120,"received_bytes":"3070336","total_bytes":3070336,"target_version":"1.1.0","target_build":2}"#.utf8)
        let status = try JSONDecoder().decode(RadarBLEFirmwareStatus.self, from: data)

        XCTAssertEqual(status.stage, "success")
        XCTAssertEqual(status.progress, 100)
        XCTAssertEqual(status.receivedBytes, 3_070_336)
        XCTAssertEqual(status.targetBuild, 2)
    }

    func testCompactControlContainsFullVerifiedManifestAndAbsoluteURL() throws {
        var manifest = makeManifest(signature: Data(repeating: 0x41, count: 71).base64EncodedString())
        manifest.releaseNotes = "not part of signed control"
        let artifactName = "\(String(repeating: "b", count: 64)).bin"
        let data = try manifest.compactControlData(
            artifactURL: try XCTUnwrap(URL(string: "https://relay.example/v1/firmware/artifacts/\(artifactName)"))
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let compact = try XCTUnwrap(object["m"] as? [String: Any])

        XCTAssertEqual(object["action"] as? String, "start")
        XCTAssertNil(object["a"])
        XCTAssertEqual(compact["s"] as? Int, manifest.schema)
        XCTAssertEqual(compact["sha"] as? String, manifest.sha256)
        XCTAssertEqual(compact["sig"] as? String, manifest.signature)
        XCTAssertEqual(compact["url"] as? String, "https://relay.example/v1/firmware/artifacts/\(artifactName)")
        XCTAssertLessThanOrEqual(data.count, 512)
    }

    func testArtifactURLResolvesRootRelativeAndRejectsCrossOriginOrUnexpectedPath() throws {
        let resolved = try FirmwareArtifactURLPolicy.resolve(
            "/v1/firmware/artifacts/dragon-radar-1.1.0.bin",
            baseURLString: "https://relay.example:8788",
            requireHTTPS: true
        )
        XCTAssertEqual(
            resolved.absoluteString,
            "https://relay.example:8788/v1/firmware/artifacts/dragon-radar-1.1.0.bin"
        )
        XCTAssertThrowsError(
            try FirmwareArtifactURLPolicy.resolve(
                "https://evil.example/v1/firmware/artifacts/dragon-radar.bin",
                baseURLString: "https://relay.example",
                requireHTTPS: true
            )
        )
        XCTAssertThrowsError(
            try FirmwareArtifactURLPolicy.resolve(
                "/downloads/dragon-radar.bin",
                baseURLString: "https://relay.example",
                requireHTTPS: true
            )
        )
    }

    func testVerifierRejectsNonNumericThreePartVersions() throws {
        let privateKey = P256.Signing.PrivateKey()
        let verifier = FirmwareManifestVerifier(publicKeyPEM: privateKey.publicKey.pemRepresentation)

        var prerelease = makeManifest(signature: "AA==")
        prerelease.version = "1.1.0-rc.1"
        XCTAssertThrowsError(try verifier.verify(prerelease)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidField("version"))
        }

        var buildMetadata = makeManifest(signature: "AA==")
        buildMetadata.minimumVersion = "1.0.0+factory"
        XCTAssertThrowsError(try verifier.verify(buildMetadata)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidField("minimum_version"))
        }

        var targetBelowMinimum = makeManifest(signature: "AA==")
        targetBelowMinimum.version = "1.0.0"
        targetBelowMinimum.minimumVersion = "1.1.0"
        XCTAssertThrowsError(try verifier.verify(targetBelowMinimum)) { error in
            XCTAssertEqual(error as? FirmwareManifestError, .invalidField("version_minimum_order"))
        }
    }

    func testOTAPowerGateAllowsThirtyPercentOrCharging() throws {
        let low = try decodeDeviceStatus(percent: 29, charging: false)
        let threshold = try decodeDeviceStatus(percent: 30, charging: false)
        let charging = try decodeDeviceStatus(percent: 5, charging: true)

        XCTAssertFalse(low.isOTAPowerReady)
        XCTAssertTrue(threshold.isOTAPowerReady)
        XCTAssertTrue(charging.isOTAPowerReady)
    }

    func testOTAProvisioningGateRequiresPairingAndServerCredentials() throws {
        XCTAssertTrue(try decodeDeviceStatus(percent: 50, charging: false).isOTAProvisioningReady)
        XCTAssertFalse(try decodeDeviceStatus(percent: 50, charging: false, paired: 0).isOTAProvisioningReady)
        XCTAssertFalse(try decodeDeviceStatus(percent: 50, charging: false, server: 0).isOTAProvisioningReady)
    }

    func testOTAOriginMustBeExplicitlyConfirmedByDeviceStatus() throws {
        let confirmed = try decodeDeviceStatus(percent: 50, charging: false, otaOrigin: 1)
        let unconfirmed = try decodeDeviceStatus(percent: 50, charging: false, otaOrigin: 0)
        let missing = try decodeDeviceStatus(percent: 50, charging: false, otaOrigin: nil)

        XCTAssertEqual(confirmed.otaOrigin, 1)
        XCTAssertTrue(confirmed.isOTAOriginConfirmed)
        XCTAssertFalse(unconfirmed.isOTAOriginConfirmed)
        XCTAssertFalse(missing.isOTAOriginConfirmed)
    }

    @MainActor
    func testReleaseMustIncreaseGlobalBuildEvenWhenSemverIsHigher() throws {
        let coordinator = makeCoordinator()
        var manifest = makeManifest(signature: "AA==")
        manifest.version = "2.0.0"
        manifest.build = 1
        let release = VerifiedFirmwareManifest(
            manifest: manifest,
            artifactURL: try XCTUnwrap(URL(string: "https://relay.example/v1/firmware/artifacts/radar.bin"))
        )
        let current = try decodeDeviceStatus(percent: 50, charging: false, build: 1, version: "1.0.0")

        coordinator.evaluate(release: release, deviceStatus: current)

        XCTAssertNotEqual(coordinator.phase, .available)
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.detail.contains("构建号"))
    }

    @MainActor
    func testReleaseSecurityCounterCannotGoBelowReportedCurrentCounter() throws {
        let coordinator = makeCoordinator()
        var manifest = makeManifest(signature: "AA==")
        manifest.build = 3
        manifest.securityCounter = 1
        let release = VerifiedFirmwareManifest(
            manifest: manifest,
            artifactURL: try XCTUnwrap(URL(string: "https://relay.example/v1/firmware/artifacts/radar.bin"))
        )
        let current = try decodeDeviceStatus(
            percent: 50,
            charging: false,
            build: 1,
            version: "1.0.0",
            securityCounter: 2
        )

        coordinator.evaluate(release: release, deviceStatus: current)

        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.detail.contains("安全计数器"))
    }

    @MainActor
    func testTargetVersionDoesNotSucceedUntilExplicit108Success() throws {
        let suiteName = "FirmwareUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = FirmwareUpdateCoordinator(defaults: defaults)
        let manifest = makeManifest(signature: "AA==")
        coordinator.availableRelease = VerifiedFirmwareManifest(
            manifest: manifest,
            artifactURL: try XCTUnwrap(URL(string: "https://relay.example/v1/firmware/artifacts/radar.bin"))
        )
        coordinator.phase = .rebooting

        coordinator.synchronize(
            status: RadarBLEFirmwareStatus(firmwareVersion: manifest.version, stage: "idle", progress: 100),
            deviceStatus: nil
        )
        XCTAssertEqual(coordinator.phase, .rebooting)
        XCTAssertTrue(coordinator.detail.contains("等待雷达 108 健康确认"))

        coordinator.synchronize(
            status: RadarBLEFirmwareStatus(
                firmwareVersion: manifest.version,
                build: manifest.build,
                stage: "success",
                progress: 100,
                targetVersion: manifest.version,
                targetBuild: manifest.build
            ),
            deviceStatus: nil
        )
        XCTAssertEqual(coordinator.phase, .succeeded)
    }

    @MainActor
    func test108SuccessRequiresCurrentVersionAndBuildToMatchTarget() throws {
        let coordinator = makeCoordinator()
        let manifest = makeManifest(signature: "AA==")
        coordinator.availableRelease = VerifiedFirmwareManifest(
            manifest: manifest,
            artifactURL: try XCTUnwrap(URL(string: "https://relay.example/v1/firmware/artifacts/radar.bin"))
        )
        coordinator.phase = .rebooting

        coordinator.synchronize(
            status: RadarBLEFirmwareStatus(
                firmwareVersion: "1.0.0",
                build: manifest.build - 1,
                stage: "success",
                progress: 100,
                targetVersion: manifest.version,
                targetBuild: manifest.build
            ),
            deviceStatus: nil
        )

        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.detail.contains("版本或构建号与目标不一致"))
    }

    @MainActor
    func testPreviousReleaseSuccessDoesNotFailNewAvailableUpdate() throws {
        let coordinator = makeCoordinator()
        let manifest = makeManifest(signature: "AA==")
        coordinator.availableRelease = VerifiedFirmwareManifest(
            manifest: manifest,
            artifactURL: try XCTUnwrap(URL(string: "https://relay.example/v1/firmware/artifacts/radar.bin"))
        )
        coordinator.phase = .available
        coordinator.detail = "发现版本 \(manifest.version)"

        coordinator.synchronize(
            status: RadarBLEFirmwareStatus(
                firmwareVersion: "1.0.13",
                build: 15,
                stage: "success",
                progress: 100,
                targetVersion: "1.0.13",
                targetBuild: 15
            ),
            deviceStatus: nil
        )

        XCTAssertEqual(coordinator.phase, .available)
        XCTAssertEqual(coordinator.progress, 0)
        XCTAssertEqual(coordinator.detail, "发现版本 \(manifest.version)")
    }

    @MainActor
    func testWaitingForOTAWifiAcknowledgesControlWithoutUsingPreviousSuccess() throws {
        let coordinator = makeCoordinator()
        let manifest = makeManifest(signature: "AA==")
        coordinator.availableRelease = VerifiedFirmwareManifest(
            manifest: manifest,
            artifactURL: try XCTUnwrap(URL(string: "https://relay.example/v1/firmware/artifacts/radar.bin"))
        )
        coordinator.phase = .sending

        coordinator.synchronize(
            status: RadarBLEFirmwareStatus(
                firmwareVersion: "1.0.13",
                build: 15,
                stage: "success",
                progress: 100,
                targetVersion: "1.0.13",
                targetBuild: 15
            ),
            deviceStatus: try decodeDeviceStatus(
                percent: 50,
                charging: true,
                wifi: "connecting",
                last: "ota_waiting_wifi"
            )
        )

        XCTAssertEqual(coordinator.phase, .sending)
        XCTAssertEqual(coordinator.progress, 0)
        XCTAssertTrue(coordinator.detail.contains("正在连接"))
    }

    @MainActor
    func testWaitingForOTAWifiHasBoundedConnectionTimeout() async throws {
        let coordinator = FirmwareUpdateCoordinator(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "FirmwareUpdateTests.\(UUID().uuidString)")),
            sendingAcknowledgementTimeout: .seconds(1),
            wifiConnectionTimeout: .milliseconds(20)
        )
        coordinator.phase = .sending

        coordinator.synchronize(
            status: nil,
            deviceStatus: try decodeDeviceStatus(
                percent: 50,
                charging: true,
                wifi: "connecting",
                last: "ota_waiting_wifi"
            )
        )

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.detail.contains("连接 OTA 网络超时"))
    }

    @MainActor
    func testOTAWifiFailureReasonIsUserFacing() throws {
        let coordinator = makeCoordinator()
        coordinator.phase = .sending

        coordinator.synchronize(
            status: nil,
            deviceStatus: try decodeDeviceStatus(
                percent: 50,
                charging: true,
                wifi: "failed",
                last: "ota_rejected_wifi_authentication"
            )
        )

        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.detail.contains("检查热点密码"))
    }

    @MainActor
    func testSendingFailsOnWriteErrorOrMissing108Acknowledgement() async throws {
        let coordinator = FirmwareUpdateCoordinator(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "FirmwareUpdateTests.\(UUID().uuidString)")),
            sendingAcknowledgementTimeout: .milliseconds(20)
        )
        coordinator.phase = .sending
        coordinator.handleFirmwareControlWriteFailure("写入雷达失败：测试")
        XCTAssertEqual(coordinator.phase, .failed)

        coordinator.phase = .sending
        coordinator.beginSendingAcknowledgementTimeout()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.detail.contains("未在限定时间内确认"))
    }

    @MainActor
    func testCancellationWaitsFor108AndFailsOnWriteErrorOrTimeout() async throws {
        let coordinator = FirmwareUpdateCoordinator(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "FirmwareUpdateTests.\(UUID().uuidString)")),
            sendingAcknowledgementTimeout: .milliseconds(20)
        )

        coordinator.phase = .canceling
        coordinator.synchronize(
            status: RadarBLEFirmwareStatus(stage: "downloading", progress: 42),
            deviceStatus: nil
        )
        XCTAssertEqual(coordinator.phase, .canceling)

        coordinator.synchronize(
            status: RadarBLEFirmwareStatus(stage: "cancelled", progress: 42),
            deviceStatus: nil
        )
        XCTAssertEqual(coordinator.phase, .canceled)

        coordinator.phase = .canceling
        coordinator.handleFirmwareControlWriteFailure("写入雷达失败：取消测试")
        XCTAssertEqual(coordinator.phase, .failed)

        coordinator.phase = .canceling
        coordinator.beginCancellationAcknowledgementTimeout()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertTrue(coordinator.detail.contains("实际更新状态未知"))
    }

    private func makeManifest(signature: String) -> FirmwareManifest {
        FirmwareManifest(
            schema: 1,
            product: "dragon-radar",
            hardware: FirmwareManifestVerifier.expectedHardware,
            version: "1.1.0",
            build: 2,
            minimumVersion: "1.0.0",
            securityCounter: 2,
            size: 3_070_336,
            sha256: String(repeating: "a", count: 64),
            signatureAlgorithm: FirmwareManifestVerifier.expectedAlgorithm,
            keyID: FirmwareManifestVerifier.expectedKeyID,
            signature: signature,
            artifactURL: "/v1/firmware/artifacts/dragon-radar-1.1.0.bin",
            channel: "stable",
            releaseNotes: nil
        )
    }

    private func decodeDeviceStatus(
        percent: Int,
        charging: Bool,
        paired: Int = 1,
        server: Int = 1,
        build: Int = 1,
        version: String = "1.0.0",
        securityCounter: Int? = nil,
        otaOrigin: Int? = 1,
        wifi: String = "connected",
        last: String = "ready"
    ) throws -> RadarBLEDeviceStatus {
        let securityField = securityCounter.map { ",\"security_counter\":\($0)" } ?? ""
        let originField = otaOrigin.map { ",\"ota_origin\":\($0)" } ?? ""
        let json = """
        {"v":1,"name":"Radar","ble":1,"paired":\(paired),"wifi":"\(wifi)","rssi":-40,"ip":"192.0.2.2","server":\(server),"relay":"ready","loc":1,"battery":{"present":true,"percent":\(percent),"voltage_mv":3900,"charging":\(charging),"discharging":false,"low":false},"last":"\(last)","fw":"\(version)","build":\(build),"hw":"esp32-s3-touch-amoled-1.75c","ota":1\(originField)\(securityField)}
        """
        return try JSONDecoder().decode(RadarBLEDeviceStatus.self, from: Data(json.utf8))
    }

    @MainActor
    private func makeCoordinator() -> FirmwareUpdateCoordinator {
        let suiteName = "FirmwareUpdateTests.\(UUID().uuidString)"
        return FirmwareUpdateCoordinator(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }
}
