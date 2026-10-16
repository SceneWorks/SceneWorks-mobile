# SceneWorks-mobile

The SceneWorks iOS app: the SwiftUI shell of SceneWorks' on-device image generation
(prompt → generate → progress → cancel → result). The app talks to the image-generation engine only through the
`GenerationEngine` protocol; the real on-device engine (Rust/MLX behind an FFI) arrives later.

## Layout

| Path | What |
| --- | --- |
| `SceneWorksMobile.xcodeproj` | The Xcode project (synchronized folders: a new file in a target's folder is part of that target, no project edit needed) and its one shared scheme, `SceneWorksMobile` |
| `SceneWorksMobile/` | The app target (`com.sceneworks.mobile`, iOS 18.0+, iPhone): `SceneWorksMobileApp` (root: `GenerateView` wired with `FakeGenerationEngine`), `GenerateView`, `GenerateViewModel`, `Generation/GenerationEngine.swift` (`GenerationEngine` protocol, `GenerationRequest`/`GenerationEvent`, and the fake engine), `Provisioning/` (model provisioning, see below), `ContentView` (placeholder) |
| `SceneWorksMobileTests/` | Unit tests (Swift Testing and XCTest), hosted in the app (`@testable import SceneWorksMobile`): `SceneWorksMobileTests` (engine and view model) and `ModelProvisionerTests` (provisioning over a fake `URLProtocol`, a fake `StorageInspector` and a temp directory) |
| `SceneWorksMobileUITests/` | UI tests (XCUITest) |
| `factory/gate.yaml`, `CODEOWNERS` | The Dark Factory merge gate's policy and the owners of its sealed paths |
| `.github/workflows/ios-tests.yml` | CI: builds and runs both test targets on an iOS Simulator |

Signing is ad hoc (`CODE_SIGN_IDENTITY = -`, no team): the project builds and tests on the simulator without an Apple
account. Device builds need a team set locally.

## Choosing the fake engine

The app's one composition point, `SceneWorksMobileApp`, reads the `SCENEWORKS_FAKE_ENGINE` launch environment variable
and picks how `FakeGenerationEngine` behaves:

| Value | Behavior |
| --- | --- |
| unset or anything else | `standard`: 4 steps, 1 second apart |
| `slow` | `slow`: 4 steps, 5 seconds apart — a run stays in progress long enough to tap Cancel |
| `fail` | `fail`: 4 steps, 200 ms apart, throwing at step 2 — the run fails with a readable message and Retry |

Set it in the scheme's Run > Arguments > Environment Variables for a manual run, or from the test target:

```swift
app.launchEnvironment["SCENEWORKS_FAKE_ENGINE"] = "slow"
app.launch()
```

The UI tests use `slow` for the cancel case and `fail` for the error/Retry case.

## Model provisioning

`SceneWorksMobile/Provisioning/` is the logic half of model delivery: no UI, just the manifest, the
transfer and the verification.

| File | What |
| --- | --- |
| `ModelManifest.swift` | `ModelManifest` (Codable): a `version` plus `components`, each with `name`, a relative `path`, a `url`, a `size` in bytes and a `sha256` hex digest |
| `ModelProvisioner.swift` | The `ModelProvisioner` actor, `ProvisioningProgress` and the typed `ProvisioningError` |
| `StorageInspector.swift` | The `StorageInspector` protocol and `VolumeStorageInspector`, the production inspector |

A run of `provision()` writes each component that is not already present and verified into
`Application Support/Models/<version>/`. Bytes land in a `.partial` file first; an interrupted
transfer resumes with an HTTP `Range: bytes=<n>-` request that appends a `206` answer (Range rather
than `URLSession` resume data, which a fake `URLProtocol` cannot produce). Only once the file's size
and streamed SHA-256 both match the manifest is it moved to its final path. The `Models` directory is
marked `isExcludedFromBackup`, progress is reported as an `AsyncThrowingStream` of `ProvisioningProgress`
(bytes done / total), and every failure is a `ProvisioningError` — `integrityFailed(component:)`,
`insufficientStorage(required:available:)`, `transferFailed`, `resumeRejected`, `invalidComponentPath`,
`fileSystemFailed` or `transferError`.

Three things are injected, so tests drive the provisioner without a network or a real volume:

| Dependency | Production | In tests |
| --- | --- | --- |
| `URLSession` | the app's session | a session whose `protocolClasses` hold a fake `URLProtocol` |
| `StorageInspector` | `VolumeStorageInspector` (`volumeAvailableCapacityForImportantUsage`) | a fake reporting a chosen free-space figure |
| models directory | `Application Support/Models` | a temporary directory |

`ModelProvisioner.live(manifest:session:)` is the production wiring. Before any request is sent the
provisioner checks free space for the bytes still to download and fails
`insufficientStorage(required:available:)` when there is not enough room.

## Running the tests

Xcode 26 with the iOS Simulator runtime. Pick any iPhone simulator (`xcrun simctl list devices available`):

```sh
xcodebuild test -project SceneWorksMobile.xcodeproj -scheme SceneWorksMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

or build once and run the tests separately:

```sh
xcodebuild build-for-testing -project SceneWorksMobile.xcodeproj -scheme SceneWorksMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project SceneWorksMobile.xcodeproj -scheme SceneWorksMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SceneWorksMobileTests
```

## Dark Factory

This repository is worked by Dark Factory. Its gate reads `factory/gate.yaml` at each pull request's base: `factory/`,
`.github/` and `CODEOWNERS` are sealed (never merged by the factory); the Xcode project, schemes, xcconfigs,
entitlements, `Info.plist`, test plans and Swift package manifests are protected; `README.md` is free; everything else needs new tests that
fail on the base and pass on the head.
