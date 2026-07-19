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
        XCTAssertTrue(app.staticTexts["CAPSULE"].waitForExistence(timeout: 5))
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
            app.descendants(matching: .any)["devices.radar.connection.status"].waitForExistence(timeout: 5),
            "Device tab should expose the radar readiness status."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["devices.empty.radar"].exists,
            "Device tab should show no registered radar instead of a demo device."
        )
        XCTAssertFalse(
            app.staticTexts["CapsuleRadar-DEMO"].exists,
            "Release-facing empty state must not rely on demo ESP data."
        )
        XCTAssertTrue(app.staticTexts["配置流程"].exists)
        XCTAssertTrue(app.staticTexts["连接雷达"].exists)
        XCTAssertTrue(app.staticTexts["状态检查"].exists)

        app.staticTexts["配置流程"].tap()
        XCTAssertTrue(app.navigationBars["配置流程"].waitForExistence(timeout: 5))
        app.navigationBars["配置流程"].buttons.element(boundBy: 0).tap()

        app.staticTexts["连接雷达"].tap()
        XCTAssertTrue(app.navigationBars["连接雷达"].waitForExistence(timeout: 5))
        app.navigationBars["连接雷达"].buttons.element(boundBy: 0).tap()

        app.staticTexts["状态检查"].tap()
        XCTAssertTrue(app.navigationBars["状态检查"].waitForExistence(timeout: 5))
        app.navigationBars["状态检查"].buttons.element(boundBy: 0).tap()

        let firmware = app.buttons["devices.firmware.open"]
        reveal(firmware)
        XCTAssertTrue(firmware.waitForExistence(timeout: 5))
        firmware.tap()
        XCTAssertTrue(app.navigationBars["固件更新"].waitForExistence(timeout: 5))
    }

    func testReviewExperienceShowsLocalMembersDisablesReminderAndCanExit() throws {
        launchApp("DRAGON_RADAR_UI_TESTING_AUTHENTICATED")
        openTab("房间")

        let start = app.buttons["rooms.reviewExperience.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["radar.reviewExperience.banner"].waitForExistence(timeout: 5),
            "Starting the review experience should open the real radar tab with a clear local-demo banner."
        )

        let eastMember = app.buttons["radar.reviewExperience.target.A11E0000-0000-4000-8000-000000000102"]
        XCTAssertTrue(eastMember.waitForExistence(timeout: 5))
        eastMember.tap()
        XCTAssertTrue(app.navigationBars["成员详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["120m"].exists)
        app.navigationBars["成员详情"].buttons.element(boundBy: 0).tap()

        let southwestMember = app.buttons["radar.reviewExperience.target.A11E0000-0000-4000-8000-000000000103"]
        XCTAssertTrue(southwestMember.waitForExistence(timeout: 5))
        southwestMember.tap()
        XCTAssertTrue(app.navigationBars["成员详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["860m"].exists)

        openTab("房间")
        let safety = app.descendants(matching: .any)["rooms.reviewExperience.safety"]
        XCTAssertTrue(safety.waitForExistence(timeout: 5))
        XCTAssertTrue(safety.label.contains("不会发送提醒"))
        let stop = app.buttons["rooms.reviewExperience.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        XCTAssertTrue(app.buttons["rooms.reviewExperience.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["本地雷达体验房"].exists)
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
        codeField.typeText("CAPSFULL")

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
            app.staticTexts["周末小队"].waitForExistence(timeout: 5),
            "Seeded authenticated state should expose the first server room as current."
        )

        let secondRoom = app.buttons["rooms.switch.CAPS-2002"]
        XCTAssertTrue(secondRoom.waitForExistence(timeout: 5))
        secondRoom.tap()

        XCTAssertTrue(
            app.staticTexts["城市漫步"].waitForExistence(timeout: 5),
            "Tapping another server-backed room should update the current room title."
        )
        let summary = app.descendants(matching: .any)["rooms.current.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            summary.label.contains("CAPS-2002") && summary.label.contains("/7"),
            "Switching room should update the current room summary while keeping the server room capacity. Actual: \(summary.label)"
        )
    }

    func testCurrentRoomDetailExposesRoomWideRadarReminderAction() throws {
        launchApp(
            "DRAGON_RADAR_UI_TESTING_AUTHENTICATED",
            "DRAGON_RADAR_UI_TESTING_SEEDED_ROOMS"
        )
        openTab("房间")

        let detail = app.buttons["rooms.current.detail.open"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        detail.tap()

        let reminder = app.buttons["rooms.reminder.send"]
        if !reminder.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(
            reminder.waitForExistence(timeout: 5),
            "Any signed-in member should see the room-wide radar reminder action."
        )
        XCTAssertTrue(reminder.isEnabled)
        XCTAssertTrue(reminder.label.contains("提醒房间成员查看雷达"))
    }

    func testRemoteAppMemberCanBeReportedWhileSelfAndDeviceHaveNoModerationMenu() throws {
        launchApp(
            "DRAGON_RADAR_UI_TESTING_AUTHENTICATED",
            "DRAGON_RADAR_UI_TESTING_SEEDED_ROOMS",
            "DRAGON_RADAR_UI_TESTING_MODERATION"
        )
        openCurrentRoomDetailAndRevealMembers()

        XCTAssertFalse(app.buttons["rooms.member.moderation.1"].exists, "Self must not expose moderation actions.")
        XCTAssertFalse(app.buttons["rooms.member.moderation.3"].exists, "Device slots must not expose moderation actions.")

        let remoteMenu = app.buttons["rooms.member.moderation.2"]
        XCTAssertTrue(remoteMenu.waitForExistence(timeout: 5))
        remoteMenu.tap()

        let report = app.buttons["举报成员"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["屏蔽成员"].exists)
        report.tap()

        XCTAssertTrue(app.descendants(matching: .any)["rooms.report.sheet"].waitForExistence(timeout: 5))
        let details = app.textViews["rooms.report.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        details.typeText("UI test moderation report")

        let submit = app.buttons["rooms.report.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()

        let caseNumber = app.staticTexts["rooms.report.caseNumber"]
        XCTAssertTrue(caseNumber.waitForExistence(timeout: 5))
        XCTAssertTrue(caseNumber.label.contains("DR-UI-0001"))
    }

    func testBlockConfirmationExplainsRoomConsequencesAndRemovesTarget() throws {
        launchApp(
            "DRAGON_RADAR_UI_TESTING_AUTHENTICATED",
            "DRAGON_RADAR_UI_TESTING_SEEDED_ROOMS",
            "DRAGON_RADAR_UI_TESTING_MODERATION"
        )
        openCurrentRoomDetailAndRevealMembers()

        let remoteMenu = app.buttons["rooms.member.moderation.2"]
        XCTAssertTrue(remoteMenu.waitForExistence(timeout: 5))
        remoteMenu.tap()
        app.buttons["屏蔽成员"].tap()

        let consequence = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "双方不能加入同一房间")
        ).firstMatch
        XCTAssertTrue(consequence.waitForExistence(timeout: 5))

        let confirm = app.buttons["rooms.moderation.block.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let status = app.staticTexts["rooms.moderation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("已屏蔽 测试成员"))
        XCTAssertFalse(app.staticTexts["测试成员"].exists)
    }

    func testSafetyCommunityListsAndUnblocksWithoutExposingModerationReference() throws {
        launchApp(
            "DRAGON_RADAR_UI_TESTING_AUTHENTICATED",
            "DRAGON_RADAR_UI_TESTING_MODERATION",
            "DRAGON_RADAR_UI_TESTING_MODERATION_BLOCKED"
        )
        openTab("我的")

        let safety = app.buttons["account.safety.open"]
        reveal(safety)
        XCTAssertTrue(safety.waitForExistence(timeout: 5))
        safety.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["account.safety.screen"].waitForExistence(timeout: 5)
        )
        let row = app.staticTexts["account.safety.block.blk_ui_seeded"]
        reveal(row)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "mod_v1_")).count,
            0,
            "Opaque moderation references must never be shown to the user."
        )

        let unblock = app.buttons["account.safety.unblock.blk_ui_seeded"]
        XCTAssertTrue(unblock.waitForExistence(timeout: 5))
        unblock.tap()
        let confirm = app.buttons["account.safety.unblock.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.descendants(matching: .any)["account.safety.blocks.empty"].waitForExistence(timeout: 5))
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

    private func openCurrentRoomDetailAndRevealMembers() {
        openTab("房间")
        let detail = app.buttons["rooms.current.detail.open"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        detail.tap()
        reveal(app.buttons["rooms.member.moderation.2"])
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<5 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }

    private func loginGateHasSignInAction() -> Bool {
        if app.buttons["login.gate.development.signin"].exists {
            return true
        }

        let appleLabel = NSPredicate(format: "label CONTAINS[c] %@", "Apple")
        return app.buttons.containing(appleLabel).firstMatch.exists
    }
}
