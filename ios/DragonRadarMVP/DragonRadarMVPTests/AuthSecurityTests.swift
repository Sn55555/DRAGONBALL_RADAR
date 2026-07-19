import XCTest
@testable import DragonRadarMVP

final class AuthSecurityTests: XCTestCase {
    func testAppleSignInNonceUsesExpectedSHA256Encoding() {
        XCTAssertEqual(
            AppleSignInNonce.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testAppleSignInNonceIsRandomAndURLSafe() throws {
        let first = try AppleSignInNonce.make(length: 64)
        let second = try AppleSignInNonce.make(length: 64)

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(second.count, 64)
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(first.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression))
        XCTAssertNotNil(second.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression))
    }
}
