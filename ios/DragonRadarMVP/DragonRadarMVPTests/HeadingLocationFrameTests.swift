import XCTest
@testable import DragonRadarMVP

final class HeadingLocationFrameTests: XCTestCase {
    func testStationaryAuthorizedLocationRenewsRelayTimestamp() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let oldStationarySample = now.addingTimeInterval(-300)

        XCTAssertEqual(
            LocationUploadPolicy.transmissionTimestamp(
                sampleTimestamp: oldStationarySample,
                now: now,
                isSharing: true,
                isAuthorized: true
            ),
            now
        )
        XCTAssertFalse(
            LocationUploadPolicy.motionSampleIsFresh(
                sampleTimestamp: oldStationarySample,
                now: now
            )
        )
    }

    func testLocationKeepaliveStopsWhenPausedUnauthorizedOrClockInvalid() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        XCTAssertNil(
            LocationUploadPolicy.transmissionTimestamp(
                sampleTimestamp: now,
                now: now,
                isSharing: false,
                isAuthorized: true
            )
        )
        XCTAssertNil(
            LocationUploadPolicy.transmissionTimestamp(
                sampleTimestamp: now,
                now: now,
                isSharing: true,
                isAuthorized: false
            )
        )
        XCTAssertNil(
            LocationUploadPolicy.transmissionTimestamp(
                sampleTimestamp: now.addingTimeInterval(6),
                now: now,
                isSharing: true,
                isAuthorized: true
            )
        )
    }

    func testMissingLocationRefreshIsAuthorizedThrottledAndSingleFlight() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        XCTAssertTrue(
            LocationUploadPolicy.shouldRequestMissingSample(
                hasLocation: false,
                isSharing: true,
                isAuthorized: true,
                requestPending: false,
                lastRequestedAt: now.addingTimeInterval(-10),
                now: now
            )
        )
        XCTAssertFalse(
            LocationUploadPolicy.shouldRequestMissingSample(
                hasLocation: false,
                isSharing: true,
                isAuthorized: true,
                requestPending: true,
                lastRequestedAt: now.addingTimeInterval(-10),
                now: now
            )
        )
        XCTAssertFalse(
            LocationUploadPolicy.shouldRequestMissingSample(
                hasLocation: false,
                isSharing: true,
                isAuthorized: true,
                requestPending: false,
                lastRequestedAt: now.addingTimeInterval(-9),
                now: now
            )
        )
        XCTAssertFalse(
            LocationUploadPolicy.shouldRequestMissingSample(
                hasLocation: true,
                isSharing: true,
                isAuthorized: true,
                requestPending: false,
                lastRequestedAt: .distantPast,
                now: now
            )
        )
    }

    func testTrueNorthHeadingQualityRequiresFreshAccurateSample() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let sample = PhoneHeadingSnapshot(
            degrees: 123.45,
            accuracyDegrees: 8,
            reference: .trueNorth,
            timestamp: now.addingTimeInterval(-2)
        )

        XCTAssertEqual(sample.degreesHundredths, 12_345)
        XCTAssertEqual(sample.accuracyHundredths, 800)
        XCTAssertEqual(sample.quality(at: now), .good)
        XCTAssertEqual(sample.quality(at: now.addingTimeInterval(6)), .stale)
    }

    func testMagneticHeadingIsKeptDistinctFromTrueNorth() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let sample = PhoneHeadingSnapshot(
            degrees: 358.75,
            accuracyDegrees: 6,
            reference: .magneticNorth,
            timestamp: now
        )

        XCTAssertEqual(sample.degreesHundredths, 35_875)
        XCTAssertEqual(sample.quality(at: now), .limited)
    }

    func testHeadingRoundingWrapsAtNorthInsteadOfEncoding360Degrees() {
        let sample = PhoneHeadingSnapshot(
            degrees: 359.999,
            accuracyDegrees: 5,
            reference: .trueNorth,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )

        XCTAssertEqual(sample.degreesHundredths, 0)
    }

    func testPhoneHeadingNeverSetsRadarHeadingValidBit() {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let sample = PhoneHeadingSnapshot(
            degrees: 90,
            accuracyDegrees: 5,
            reference: .trueNorth,
            timestamp: timestamp
        )
        let snapshot = LocationSnapshot(
            latE7: 311_234_567,
            lonE7: 121_123_456,
            horizontalAccuracyCM: 450,
            speedCMS: 120,
            courseDeg100: 27_000,
            phoneHeading: sample,
            isReducedAccuracy: false,
            timestamp: timestamp
        )

        let frame = snapshot.locationFrameData
        XCTAssertEqual(frame.count, 28)
        XCTAssertEqual(frame[0], 1)
        XCTAssertEqual(frame[1] & 0b0000_0100, 0, "Phone heading is not radar yaw")
        XCTAssertEqual(readUInt16(frame, at: 20), 27_000, "Course keeps its own field")
        XCTAssertEqual(readUInt16(frame, at: 22), 0, "Unverified radar heading stays empty")
    }

    func testReducedAccuracyAndMissingCourseAreEncodedWithoutFalseHeading() {
        let snapshot = LocationSnapshot(
            latE7: 0,
            lonE7: 0,
            horizontalAccuracyCM: 2_000,
            speedCMS: 0,
            courseDeg100: nil,
            phoneHeading: nil,
            isReducedAccuracy: true,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )

        let frame = snapshot.locationFrameData
        XCTAssertEqual(frame[1] & 0b0000_0011, 0b0000_0011)
        XCTAssertEqual(frame[1] & 0b0000_0100, 0)
        XCTAssertEqual(readUInt16(frame, at: 20), 0)
        XCTAssertEqual(readUInt16(frame, at: 22), 0)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
