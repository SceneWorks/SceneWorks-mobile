import SwiftUI

struct GenerateView: View {
    @State private var viewModel: GenerateViewModel

    init(engine: any GenerationEngine) {
        _viewModel = State(initialValue: GenerateViewModel(engine: engine))
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
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canGenerate)
                .accessibilityIdentifier("retryGenerateButton")
            } else {
                Button("Generate") {
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
            }

            Spacer()
        }
        .padding()
        .onDisappear {
            viewModel.cancelGeneration()
        }
    }
}