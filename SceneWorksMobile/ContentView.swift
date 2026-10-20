import Foundation
import SwiftUI

/// The app's root: it asks the provisioner whether the models are already
/// present and verified, and shows the generate screen when they are — or the
/// first-run provisioning screen when they are not.
struct AppRootView: View {
    @State private var viewModel: ProvisioningViewModel
    private let engine: any GenerationEngine
    private let photoSaver: any PhotoLibrarySaving

    init(
        engine: any GenerationEngine,
        provisioner: ModelProvisioner,
        manifest: ModelManifest,
        storage: any StorageInspector,
        photoSaver: any PhotoLibrarySaving
    ) {
        self.engine = engine
        self.photoSaver = photoSaver
        _viewModel = State(initialValue: ProvisioningViewModel(provisioner: provisioner, manifest: manifest, storage: storage))
    }

    var body: some View {
        Group {
            if viewModel.state == .ready {
                GenerateView(engine: engine, saver: photoSaver)
            } else {
                ProvisioningView(viewModel: viewModel)
            }
        }
        .task {
            // The app root asking whether the models are ready and whether there
            // is room for them. A ready release skips the screen entirely.
            if await viewModel.isReady() {
                viewModel.state = .ready
                return
            }
            await viewModel.checkStorage()
        }
    }
}
