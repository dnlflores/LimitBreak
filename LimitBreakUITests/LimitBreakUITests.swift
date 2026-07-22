//
//  LimitBreakUITests.swift
//  LimitBreakUITests
//

import XCTest

final class LimitBreakUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Core loop: start a session, add an exercise, log a set, and verify the
    /// first-ever record triggers the LimitBreak celebration.
    @MainActor
    func testLogSetTriggersLimitBreak() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-skip-splash", "-in-memory-store"]
        app.launch()

        let trainTab = app.buttons["Train"]
        XCTAssertTrue(trainTab.waitForExistence(timeout: 5))
        trainTab.tap()

        let startButton = app.buttons["START SESSION"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        let addExercise = app.buttons["Add Exercise"]
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        addExercise.tap()

        let benchRow = app.staticTexts["Barbell Bench Press"]
        XCTAssertTrue(benchRow.waitForExistence(timeout: 5))

        let pickerShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pickerShot.name = "exercise-picker"
        pickerShot.lifetime = .keepAlways
        add(pickerShot)

        benchRow.tap()

        let logSet = app.buttons["LOG SET"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 5))
        logSet.tap()

        // First-ever set is a new ceiling — the LimitBreak overlay must appear.
        let banner = app.staticTexts["LIMITBREAK TRIGGERED"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))

        // Dismiss and confirm the set row landed with its PR crown.
        banner.tap()
        XCTAssertTrue(app.staticTexts["SET 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PR"].exists)
    }

    /// Forge sheet: every section renders, and creating a movement lands it
    /// in the Library. Captures a screenshot of the scrolled sheet for review.
    @MainActor
    func testForgeSheetCreatesExercise() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-skip-splash", "-in-memory-store", "-open-tab", "3", "-open-forge"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Forge Exercise"].waitForExistence(timeout: 5))

        let nameField = app.textFields["Exercise name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Landmine Belt Squat")

        app.swipeUp()
        app.swipeUp()

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "forge-sheet-bottom"
        attachment.lifetime = .keepAlways
        add(attachment)

        let forgeButton = app.buttons["FORGE EXERCISE"]
        XCTAssertTrue(forgeButton.waitForExistence(timeout: 3))
        XCTAssertTrue(forgeButton.isEnabled)
        forgeButton.tap()

        // Sheet dismisses back into the Library, new movement present.
        XCTAssertTrue(app.staticTexts["Landmine Belt Squat"].waitForExistence(timeout: 5))
    }
}
