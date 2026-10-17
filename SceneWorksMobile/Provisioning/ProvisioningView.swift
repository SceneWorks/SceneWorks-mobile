import Foundation
import SwiftUI

/// The first-run provisioning screen: what is being downloaded, how far along,
/// and how to start over after a failure.
struct ProvisioningView: View {
    @State private var viewModel: ProvisioningViewModel

    init(viewModel: ProvisioningViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("SceneWorks")
                .font(.largeTitle.bold())

            Text("Preparing the image models")
                .font(.title3)

            // The components with their sizes.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.components, id: \.name) { component in
                    HStack {
                        Text(component.name)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: component.size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("provisioningComponent-\(component.name)")
                }
            }

            // The overall determinate progress.
            if viewModel.state == .downloading {
                ProgressView(value: viewModel.fraction)
                    .accessibilityLabel("Provisioning progress")
                    .accessibilityValue("\(Int(viewModel.fraction * 100))%")
                    .accessibilityIdentifier("provisioningProgress")
            }

            // The failure, and the way to try again.
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("errorMessage")
            }

            switch viewModel.state {
            case .notReady:
                Button("Download") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("downloadButton")
            case .failed:
                Button("Retry") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("retryButton")
            case .noSpace:
                // Not enough room: the required and available figures are shown, and
                // there is nothing to download.
                VStack(spacing: 4) {
                    Text("Required: \(ByteCountFormatter.string(fromByteCount: viewModel.requiredBytes ?? 0, countStyle: .file))")
                    Text("Available: \(ByteCountFormatter.string(fromByteCount: viewModel.availableBytes ?? 0, countStyle: .file))")
                }
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("storageWarning")
            default:
                EmptyView()
            }

            Spacer()
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provisioningView")
        .onDisappear {
            viewModel.cancel()
        }
    }
}
