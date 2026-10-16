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
}
