import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("LaunchPad")
                .font(.largeTitle)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
