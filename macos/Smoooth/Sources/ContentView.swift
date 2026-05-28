import SwiftUI
import SmooothCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Smoooth")
                .font(.largeTitle.bold())
            Text("Native macOS • Core v\(SmooothCore.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 280)
    }
}

#Preview {
    ContentView()
}
