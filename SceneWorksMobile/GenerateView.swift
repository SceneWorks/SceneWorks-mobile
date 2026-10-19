import SwiftUI

struct GenerateView: View {
    @State private var viewModel: GenerateViewModel
    @State private var saveViewModel: SaveViewModel
    /// Identifies the result currently on screen, so a save's outcome is only
    /// shown for the result it belongs to.
    @State private var resultToken: SaveViewModel.ResultToken

    init(engine: any GenerationEngine, saver: any PhotoLibrarySaving) {
        _viewModel = State(initialValue: GenerateViewModel(engine: engine))
        _saveViewModel = State(initialValue: SaveViewModel(saver: saver))
        _resultToken = State(initialValue: SaveViewModel.ResultToken())
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 20) {
            Text("SceneWorks")
                .font(.largeTitle.bold())

            TextField("Describe an image", text: $viewModel.prompt)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("promptField")

            if viewModel.state == .failed {
                Button("Retry") {
                    saveViewModel.reset()
                    resultToken = SaveViewModel.ResultToken()
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canGenerate)
                .accessibilityIdentifier("retryGenerateButton")
            } else {
                Button("Generate") {
                    saveViewModel.reset()
                    resultToken = SaveViewModel.ResultToken()
                    viewModel.generate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canGenerate)
                .accessibilityIdentifier("generateButton")
            }

            if viewModel.state == .generating {
                Button("Cancel") {
                    viewModel.cancelGeneration()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cancelButton")

                ProgressView(value: viewModel.progress)
                    .accessibilityLabel("Generation progress")
                    .accessibilityValue("\(Int(viewModel.progress * 100))%")
                    .accessibilityIdentifier("generationProgress")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("errorMessage")
            }

            if let image = viewModel.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Generated image")
                    .accessibilityIdentifier("resultImage")

                // Once a result exists it can be saved to Photos and shared.
                if let generatedImage = viewModel.generatedImage {
                    HStack(spacing: 16) {
                        Button("Save") {
                            Task { await saveViewModel.save(image: generatedImage, seed: viewModel.seed, result: resultToken) }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("saveButton")

                        ShareLink(
                            item: ExportedImage(image: generatedImage, seed: viewModel.seed),
                            preview: SharePreview("SceneWorks image", image: Image(uiImage: image))
                        )
                        .accessibilityIdentifier("shareButton")
                    }

                    switch saveViewModel.message(for: resultToken) {
                    case .saved:
                        Text("Saved to Photos")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("saveConfirmation")
                    case .photosAccessDenied:
                        Text("SceneWorks can't add to Photos. Allow it in Settings, then try again.")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("saveDeniedMessage")
                    case let .saveFailed(detail):
                        Text("Couldn't save the image: \(detail)")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("saveErrorMessage")
                    case nil:
                        EmptyView()
                    }
                }
            }

            Spacer()
        }
        .padding()
        .onDisappear {
            viewModel.cancelGeneration()
        }
    }
}