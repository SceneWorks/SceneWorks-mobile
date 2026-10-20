# SceneWorks-mobile

The SceneWorks iOS app: the SwiftUI shell of SceneWorks' on-device image generation
(prompt → generate → progress → cancel → result). The app talks to the image-generation engine only through the
`GenerationEngine` protocol; the real on-device engine (Rust/MLX behind an FFI) arrives later.

## Layout

| Path | What |
| --- | --- |
| `SceneWorksMobile.xcodeproj` | The Xcode project (synchronized folders: a new file in a target's folder is part of that target, no project edit needed) and its one shared scheme, `SceneWorksMobile` |
| `SceneWorksMobile/` | The app target (`com.sceneworks.mobile`, iOS 18.0+, iPhone): `SceneWorksMobileApp` (composition point, reads the launch environment), `AppRootView` in `ContentView.swift` (the root: asks the provisioner whether the models are ready — `GenerateView` when they are, `ProvisioningView` when they are not), `GenerateView`, `GenerateViewModel`, `Generation/GenerationEngine.swift` (`GenerationEngine` protocol, `GenerationRequest`/`GenerationEvent`, and the fake engine), `Provisioning/` (model provisioning and the first-run screen, see below), `Sharing/` (save-to-Photos and share, see below) |
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

## Choosing the fake model source

The same composition point reads two more launch environment variables, picked from the test target
the same way (`app.launchEnvironment[…]`). Together they drive the first-run provisioning screen:

| Variable | Values | Behavior |
| --- | --- | --- |
| `SCENEWORKS_FAKE_DOWNLOADS` | unset · `ok` · `fail` · `nospace` | How the fake model source answers. Unset or `ok` serves every component successfully. `fail` answers the first request 500 (so a Download fails and Retry is offered) and succeeds on subsequent requests, so Retry completes. `nospace` makes the storage inspector report no room, so the precheck fails before any request and the screen shows the required/available space with no Download. |
| `SCENEWORKS_RESET_MODELS` | `1` · unset | When `1`, the provisioned models are deleted at launch, so the app starts from "not ready" and shows the provisioning screen instead of finding the release already on disk. |

A fresh launch (no models) shows the provisioning screen; tapping Download runs the provisioner, and
once the release is on disk a relaunch without `SCENEWORKS_RESET_MODELS` goes straight to the
generate screen.

## Save to Photos and share

Once a generation shows its result, the generate screen offers a **Save** button
(`saveButton`) and a **Share** control (`shareButton`). `SceneWorksMobile/Sharing/` is
that feature end to end:

| File | What |
| --- | --- |
| `ImageExporter.swift` | Encodes a `GeneratedImage` as lossless PNG (ImageIO) and names it `SceneWorks-<seed>.png` |
| `PhotoLibrarySaving.swift` | The `PhotoLibrarySaving` seam and `PHPhotoLibraryPhotoSaver`, the production saver (add-only authorization) |
| `FakePhotoLibrarySaver.swift` | A `PhotoLibrarySaving` that reports a chosen authorization from the launch environment, so UI tests need no system prompt |
| `ExportedImage.swift` | The result as a `Transferable` PNG for the `ShareLink` |
| `SaveViewModel.swift` | The `@MainActor` view model: encodes, saves, and reports the outcome |

A denied or restricted Photos access shows a message explaining how to allow it;
a successful save shows a confirmation (`saveConfirmation`). The app declares its
Photos add access via the `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` build
setting.

Like the other fakes, the photo library is chosen at the composition point from the
launch environment:

| Variable | Values | Behavior |
| --- | --- | --- |
| `SCENEWORKS_FAKE_PHOTOS` | unset · `authorized` · `denied` · `restricted` | The authorization the fake photo library reports. Unset or `authorized` saves; `denied` or `restricted` shows the access-denied message and saves nothing. Unset uses the real `PHPhotoLibrary`. |

Set it in the scheme's Run > Arguments > Environment Variables, or from the UI test
target: `app.launchEnvironment["SCENEWORKS_FAKE_PHOTOS"] = "authorized"`.

## Model provisioning

`SceneWorksMobile/Provisioning/` is model delivery end to end: the manifest, the transfer, the
verification, and the first-run screen that surfaces it as onboarding. The app root
(`AppRootView`) asks the provisioner whether the release is already on disk and verified; when it
is, the generate screen shows, and when it is not, the `ProvisioningView` does. The view model
drives a `ModelProvisioner` run and reports its byte progress as one overall determinate fraction.

| File | What |
| --- | --- |
| `ModelManifest.swift` | `ModelManifest` (Codable): a `version` plus `components`, each with `name`, a relative `path`, a `url`, a `size` in bytes and a `sha256` hex digest |
| `ModelProvisioner.swift` | The `ModelProvisioner` actor, `ProvisioningProgress` and the typed `ProvisioningError` |
| `StorageInspector.swift` | The `StorageInspector` protocol and `VolumeStorageInspector`, the production inspector |
| `ProvisioningViewModel.swift` | The `@MainActor` `ProvisioningViewModel` that drives a `ModelProvisioner` run and reduces byte progress to one overall fraction |
| `ProvisioningView.swift` | The first-run onboarding screen: the components with their sizes, overall determinate progress, a Download / Retry control, and the required/available space when there is not enough |
| `FakeModelSource.swift` | The model source while there is no real hosting: a bundled manifest of small synthetic components, served in-process by a `URLProtocol` on the provisioner's session — the seam real hosting replaces |

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
