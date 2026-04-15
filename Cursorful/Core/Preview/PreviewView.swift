import AppKit
import MetalKit
import SwiftUI

/// NSViewRepresentable wrapping an MTKView bound to a `PreviewRenderer`.
struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer.context.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = renderer
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
