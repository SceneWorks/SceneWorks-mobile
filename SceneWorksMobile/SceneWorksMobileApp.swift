import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

/// The SceneWorks mobile app: the SwiftUI shell of SceneWorks' on-device image generation.
@main
struct SceneWorksMobileApp: App {
    /// The one composition point: the launch environment picks how the fake engine behaves,
    /// how the fake model source behaves, how the fake photo library behaves, and the root that
    /// shows. Read only here (E8).
    private var root: some View {
        let environment = ProcessInfo.processInfo.environment
        let downloads = environment["SCENEWORKS_FAKE_DOWNLOADS"]
        let resetModels = environment["SCENEWORKS_RESET_MODELS"] == "1"
        let photos = environment["SCENEWORKS_FAKE_PHOTOS"]

        if resetModels {
            resetProvisionedModels()
        }

        let manifest = FakeModelSource.manifest
        let (session, storage) = FakeModelSource.session(fail: downloads == "fail", nospace: downloads == "nospace")
        let modelsDirectory = (try? ModelProvisioner.applicationSupportModelsDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Models", isDirectory: true)
        let provisioner = ModelProvisioner(
            manifest: manifest,
            session: session,
            storage: storage,
            modelsDirectory: modelsDirectory
        )
        let engine = FakeGenerationEngine(mode: fakeEngineMode)
        let photoSaver: any PhotoLibrarySaving =
            photos == "authorized" || photos == "denied" || photos == "restricted"
                ? FakePhotoLibrarySaver(authorization: FakePhotoAuthorization(environment: environment))
                : PHPhotoLibraryPhotoSaver()
        return AppRootView(
            engine: engine,
            provisioner: provisioner,
            manifest: manifest,
            storage: storage,
            photoSaver: photoSaver
        )
    }

    var body: some Scene {
        WindowGroup {
            root
        }
    }

    /// How `FakeGenerationEngine` behaves, picked from the launch environment.
    private var fakeEngineMode: FakeGenerationEngine.Mode {
        switch ProcessInfo.processInfo.environment["SCENEWORKS_FAKE_ENGINE"] {
        case "slow": return .slow
        case "fail": return .fail
        default: return .standard
        }
    }

    /// Clears the provisioned models so a launch with `SCENEWORKS_RESET_MODELS` starts from
    /// "not ready" instead of finding the release already on disk.
    private func resetProvisionedModels() {
        guard let directory = try? ModelProvisioner.applicationSupportModelsDirectory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
