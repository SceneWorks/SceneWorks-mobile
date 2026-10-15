import Testing
@testable import SceneWorksMobile

struct SceneWorksMobileTests {
    @Test func appModuleIsTestable() {
        _ = ContentView()
        #expect(Bool(true))
    }
}
