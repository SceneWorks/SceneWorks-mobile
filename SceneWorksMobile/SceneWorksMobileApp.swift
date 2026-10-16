import SwiftUI

/// The SceneWorks mobile app: the SwiftUI shell of SceneWorks' on-device image generation.
@main
struct SceneWorksMobileApp: App {
    var body: some Scene {
        WindowGroup {
            GenerateView(engine: FakeGenerationEngine())
        }
    }
}
