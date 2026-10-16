import Foundation
import SwiftUI

/// The SceneWorks mobile app: the SwiftUI shell of SceneWorks' on-device image generation.
@main
struct SceneWorksMobileApp: App {
    var body: some Scene {
        WindowGroup {
            GenerateView(engine: FakeGenerationEngine(mode: fakeEngineMode))
        }
    }

    /// The one composition point: the launch environment picks how the fake engine behaves.
    private var fakeEngineMode: FakeGenerationEngine.Mode {
        switch ProcessInfo.processInfo.environment["SCENEWORKS_FAKE_ENGINE"] {
        case "slow": return .slow
        case "fail": return .fail
        default: return .standard
        }
    }
}