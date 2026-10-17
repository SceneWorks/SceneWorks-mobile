import XCTest

final class SceneWorksMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - First-run provisioning

    @MainActor
    func testProvisioningDownloadsThenShowsGenerateScreen() {
        let app = XCUIApplication()
        app.launchEnvironment["SCENEWORKS_RESET_MODELS"] = "1"
        app.launch()

        // A fresh launch shows the provisioning screen, not the generate screen.
        let downloadButton = app.buttons["downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 30))
        XCTAssertFalse(app.textFields["promptField"].exists)

        // Download shows progress, then the generate screen.
        downloadButton.tap()
        XCTAssertTrue(app.progressIndicators["provisioningProgress"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textFields["promptField"].waitForExistence(timeout: 30))

        // A relaunch with the models present goes straight to the generate screen.
        app.terminate()
        app.launchEnvironment["SCENEWORKS_RESET_MODELS"] = nil
        app.launch()
        XCTAssertTrue(app.textFields["promptField"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["downloadButton"].exists)
    }

    @MainActor
    func testProvisioningFailureShowsErrorAndRetryCompletes() {
        let app = XCUIApplication()
        app.launchEnvironment["SCENEWORKS_RESET_MODELS"] = "1"
        app.launchEnvironment["SCENEWORKS_FAKE_DOWNLOADS"] = "fail"
        app.launch()

        let downloadButton = app.buttons["downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 30))
        downloadButton.tap()

        // The run fails: an error and a Retry appear.
        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["errorMessage"].label.isEmpty)
        XCTAssertTrue(app.buttons["retryButton"].waitForExistence(timeout: 5))

        // The source succeeds on retry (this session only fails its first pass).
        app.buttons["retryButton"].tap()
        XCTAssertTrue(app.progressIndicators["provisioningProgress"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textFields["promptField"].waitForExistence(timeout: 30))
    }

    @MainActor
    func testProvisioningWithoutSpaceShowsSizesAndNoDownload() {
        let app = XCUIApplication()
        app.launchEnvironment["SCENEWORKS_RESET_MODELS"] = "1"
        app.launchEnvironment["SCENEWORKS_FAKE_DOWNLOADS"] = "nospace"
        app.launch()

        // The component list is shown, the required and available space are shown,
        // and Download is not offered.
        XCTAssertTrue(app.staticTexts["provisioningComponent-unet"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["storageWarning"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["downloadButton"].exists)
    }

    // MARK: - Generate

    @MainActor
    func testGenerateShowsProgressThenResult() {
        let app = XCUIApplication()
        app.launchEnvironment["SCENEWORKS_RESET_MODELS"] = "1"
        app.launch()

        // Skip past provisioning to the generate screen.
        app.buttons["downloadButton"].waitForExistence(timeout: 30)
        app.buttons["downloadButton"].tap()
        XCTAssertTrue(app.textFields["promptField"].waitForExistence(timeout: 30))

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
        app.launchEnvironment["SCENEWORKS_RESET_MODELS"] = "1"
        app.launch()

        // Skip past provisioning to the generate screen.
        app.buttons["downloadButton"].waitForExistence(timeout: 30)
        app.buttons["downloadButton"].tap()

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
        app.launchEnvironment["SCENEWORKS_RESET_MODELS"] = "1"
        app.launch()

        // Skip past provisioning to the generate screen.
        app.buttons["downloadButton"].waitForExistence(timeout: 30)
        app.buttons["downloadButton"].tap()
        XCTAssertTrue(app.textFields["promptField"].waitForExistence(timeout: 30))

        let promptField = app.textFields["promptField"]
        promptField.tap()
        promptField.typeText("A field of wildflowers")
        app.buttons["generateButton"].tap()

        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["errorMessage"].label.isEmpty)
        XCTAssertTrue(app.buttons["retryGenerateButton"].exists)
    }
}
