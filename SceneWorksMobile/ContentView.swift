import SwiftUI

/// Placeholder root view. The prompt → generate → progress → cancel → result flow replaces it.
struct ContentView: View {
    var body: some View {
        Text("SceneWorks")
            .font(.largeTitle)
            .accessibilityIdentifier("title")
            .padding()
    }
}

#Preview {
    ContentView()
}
