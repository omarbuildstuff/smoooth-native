import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct SmooothApp: App {
    init() {
        let args = CommandLine.arguments
        // Headless Home snapshot: `Smoooth --render-home <path.png>`
        if let i = args.firstIndex(of: "--render-home"), i + 1 < args.count {
            Self.renderHome(to: args[i + 1]); exit(0)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }.windowResizability(.contentSize)
    }

    @MainActor
    static func renderHome(to path: String) {
        let view = HomeView(startRevealed: true, onImport: {}, onRecord: {})
            .environment(\.theme, Theme("dark"))
            .frame(width: 1280, height: 820)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        writePNG(cg, to: path)
    }

    static func writePNG(_ cg: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
