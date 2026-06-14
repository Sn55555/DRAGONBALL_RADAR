import XCTest

final class LaunchReadinessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testUnauthenticatedLaunchShowsLoginGateBeforeFeatureTabs() throws {
        launchApp()

        XCTAssertTrue(
            app.descendants(matching: .any)["login.gate.screen"].waitForExistence(timeout: 5),
            "Unauthenticated launch should show a dedicated login gate."
        )
        XCTAssertTrue(
            loginGateHasSignInAction(),
            "Login gate should expose a sign in action."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["app.shell.tabs"].exists,
            "Feature tabs should not be visible before login."
        )
    }

    func testDeviceTabShowsNoDemoESPAndSetupStatus() throws {
        launchApp("DRAGON_RADAR_UI_TESTING_AUTHENTICATED")

        openTab("设备")

        XCTAssertTrue(
            app.descendants(matching: .any)["devices.esp.work.status"].waitForExistence(timeout: 5),
            "Device tab should expose the ESP readiness status."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["devices.empty.esp"].exists,
            "Device tab should show no registered ESP instead of a demo device."
        )
        XCTAssertFalse(
            app.staticTexts["CapsuleRadar-DEMO"].exists,
            "Release-facing empty state must not rely on demo ESP data."
        )
    }

    func testFullRoomJoinShowsStableUserFacingError() throws {
        launchApp(
            "DRAGON_RADAR_UI_TESTING_AUTHENTICATED",
            "DRAGON_RADAR_UI_TESTING_ROOM_FULL"
        )
        openTab("房间")

        let openJoin = app.buttons["rooms.join.open"]
        XCTAssertTrue(openJoin.waitForExistence(timeout: 5))
        openJoin.tap()

        let codeField = app.textFields["rooms.join.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 5))
        codeField.tap()
        codeField.typeText("KAMEFULL")

        let submit = app.buttons["rooms.join.submit"].exists ? app.buttons["rooms.join.submit"] : app.buttons["加入"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()

        let status = app.staticTexts["rooms.join.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(
            status.label.contains("房间已满，最多 7 组"),
            "Full-room join should keep the user in the sheet and show a stable, actionable error. Actual: \(status.label)"
        )
    }

    func testSwitchRoomUpdatesCurrentRoomWithoutDemoState() throws {
        launchApp(
            "DRAGON_RADAR_UI_TESTING_AUTHENTICATED",
            "DRAGON_RADAR_UI_TESTING_SEEDED_ROOMS"
        )
        openTab("房间")

        XCTAssertTrue(
            app.staticTexts["西都小队"].waitForExistence(timeout: 5),
            "Seeded authenticated state should expose the first server room as current."
        )

        let secondRoom = app.buttons["rooms.switch.KAME-2002"]
        XCTAssertTrue(secondRoom.waitForExistence(timeout: 5))
        secondRoom.tap()

        XCTAssertTrue(
            app.staticTexts["龟屋频道"].waitForExistence(timeout: 5),
            "Tapping another server-backed room should update the current room title."
        )
        let summary = app.descendants(matching: .any)["rooms.current.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            summary.label.contains("KAME-2002") && summary.label.contains("/7"),
            "Switching room should update the current room summary while keeping the server room capacity. Actual: \(summary.label)"
        )
    }

    func testLocationPermissionDeniedShowsActionableStatus() throws {
        launchApp(
            "DRAGON_RADAR_UI_TESTING_AUTHENTICATED",
            "DRAGON_RADAR_UI_TESTING_LOCATION_DENIED"
        )
        openTab("我的")

        XCTAssertTrue(
            app.descendants(matching: .any)["account.location.panel"].waitForExistence(timeout: 5),
            "Account tab should expose the location bridge panel."
        )

        let uploadStatus = app.staticTexts["account.location.header.status"]
        XCTAssertTrue(uploadStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(
            uploadStatus.label.contains("定位权限不可用"),
            "Denied location permission should stop automatic sharing and explain the blocking cause. Actual: \(uploadStatus.label)"
        )

        let error = app.staticTexts["account.location.error"]
        if error.exists {
            XCTAssertEqual(error.label, "定位权限不可用")
        }
    }

    private func launchApp(_ extraArguments: String...) {
        app = XCUIApplication()
        app.launchArguments = ["DRAGON_RADAR_UI_TESTING"] + extraArguments
        app.launch()
    }

    private func openTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
            return
        }
        app.buttons[title].tap()
    }

    private func loginGateHasSignInAction() -> Bool {
        if app.buttons["login.gate.development.signin"].exists {
            return true
        }

        let appleLabel = NSPredicate(format: "label CONTAINS[c] %@", "Apple")
        return app.buttons.containing(appleLabel).firstMatch.exists
    }
}
