# SceneWorks-mobile

The SceneWorks iOS app: the SwiftUI shell of SceneWorks' on-device image generation
(prompt → generate → progress → cancel → result). The app talks to the image-generation engine only through the
`GenerationEngine` protocol; the real on-device engine (Rust/MLX behind an FFI) arrives later.

## Layout

| Path | What |
| --- | --- |
| `SceneWorksMobile.xcodeproj` | The Xcode project (synchronized folders: a new file in a target's folder is part of that target, no project edit needed) and its one shared scheme, `SceneWorksMobile` |
| `SceneWorksMobile/` | The app target (`com.sceneworks.mobile`, iOS 18.0+, iPhone): `SceneWorksMobileApp`, `ContentView`, `Generation/GenerationEngine.swift` |
| `SceneWorksMobileTests/` | Unit tests (Swift Testing and XCTest), hosted in the app (`@testable import SceneWorksMobile`) |
| `SceneWorksMobileUITests/` | UI tests (XCUITest) |
| `factory/gate.yaml`, `CODEOWNERS` | The Dark Factory merge gate's policy and the owners of its sealed paths |
| `.github/workflows/ios-tests.yml` | CI: builds and runs both test targets on an iOS Simulator |

Signing is ad hoc (`CODE_SIGN_IDENTITY = -`, no team): the project builds and tests on the simulator without an Apple
account. Device builds need a team set locally.

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
