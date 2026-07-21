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
        app.launch()

        app.buttons["Train"].tap()

        let startButton = app.buttons["START SESSION"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        let addExercise = app.buttons["Add Exercise"]
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        addExercise.tap()

        let benchRow = app.staticTexts["Barbell Bench Press"]
        XCTAssertTrue(benchRow.waitForExistence(timeout: 5))
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
}
