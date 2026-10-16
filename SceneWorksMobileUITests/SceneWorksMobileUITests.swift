import XCTest

final class SceneWorksMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGenerateShowsProgressThenResult() {
        let app = XCUIApplication()
        app.launch()

        let promptField = app.textFields["promptField"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 30))
        promptField.tap()
        promptField.typeText("A field of wildflowers")

        let generateButton = app.buttons["generateButton"]
        XCTAssertTrue(generateButton.isEnabled)
        generateButton.tap()

        XCTAssertTrue(app.progressIndicators["generationProgress"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.images["resultImage"].waitForExistence(timeout: 30))
    }

    @MainActor
    func testCancelReturnsToReadyPrompt() {
        let app = XCUIApplication()
        app.launchEnvironment["SCENEWORKS_FAKE_ENGINE"] = "slow"
        app.launch()

        let promptField = app.textFields["promptField"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 30))
        promptField.tap()
        promptField.typeText("A field of wildflowers")
        app.buttons["generateButton"].tap()

        let cancelButton = app.buttons["cancelButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 30))
        cancelButton.tap()

        let generateButton = app.buttons["generateButton"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 5))
        XCTAssertTrue(generateButton.isEnabled)
        XCTAssertFalse(app.buttons["cancelButton"].exists)
    }

    @MainActor
    func testFailureShowsMessageAndRetry() {
        let app = XCUIApplication()
        app.launchEnvironment["SCENEWORKS_FAKE_ENGINE"] = "fail"
        app.launch()

        let promptField = app.textFields["promptField"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 30))
        promptField.tap()
        promptField.typeText("A field of wildflowers")
        app.buttons["generateButton"].tap()

        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["errorMessage"].label.isEmpty)
        XCTAssertTrue(app.buttons["retryGenerateButton"].exists)
    }
}
