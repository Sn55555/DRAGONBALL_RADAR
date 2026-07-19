import UIKit
import XCTest

final class BrandAssetTests: XCTestCase {
    func testRequestedMangaAssetsRemainInApplicationBundle() {
        XCTAssertNotNil(UIImage(named: "LoginMangaPanel"))
        XCTAssertNotNil(UIImage(named: "CloudRiderCutout"))
    }
}
