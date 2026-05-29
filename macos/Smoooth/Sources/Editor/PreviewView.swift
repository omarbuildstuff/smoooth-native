import SwiftUI
import AVFoundation
import CoreImage
import CoreGraphics
import SmooothCore

/// Live preview: AVPlayer drives the clock during playback; while paused it seeks
/// for exact-frame scrubbing. Each tick a source frame (+ webcam) is composited via
/// SceneRenderer and shown in the layer.
struct PreviewView: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsGravity = .resizeAspect
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        context.coordinator.configureIfNeeded()
    }

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private let model: EditorModel
        private weak var view: PreviewNSView?
        private var mainPlayer: AVPlayer?
        private var mainOutput: AVPlayerItemVideoOutput?
        private var webcamPlayer: AVPlayer?
        private var webcamOutput: AVPlayerItemVideoOutput?
        private var displayLink: CADisplayLink?
        private var configuredVideoURL: URL?
        private var configuredWebcamURL: URL?
        private var lastMainBuffer: CVPixelBuffer?
        private var lastWebcamBuffer: CVPixelBuffer?
        private var lastClockWriteback: Double = -1
        private var renderInFlight = false
        private let renderQueue = DispatchQueue(label: "com.smoooth.preview.render", qos: .userInteractive)
        private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        init(model: EditorModel) { self.model = model }

        func attach(to view: PreviewNSView) {
            self.view = view
            // CADisplayLink is vsync-locked → steady cadence (Timer jittered, which
            // is what made the zoom look "saccadé"). macOS 14+.
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func teardown() {
            displayLink?.invalidate(); displayLink = nil
            mainPlayer?.pause(); webcamPlayer?.pause()
        }

        @objc private func tick() { render() }

        func configureIfNeeded() {
            if model.videoURL != configuredVideoURL {
                configuredVideoURL = model.videoURL
                lastMainBuffer = nil
                if let url = model.videoURL {
                    let item = AVPlayerItem(url: url)
                    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(out)
                    let player = AVPlayer(playerItem: item)
                    player.actionAtItemEnd = .pause
                    mainPlayer = player; mainOutput = out
                } else { mainPlayer = nil; mainOutput = nil }
            }
            if model.webcamVideoURL != configuredWebcamURL {
                configuredWebcamURL = model.webcamVideoURL
                lastWebcamBuffer = nil
                if let url = model.webcamVideoURL {
                    let item = AVPlayerItem(url: url)
                    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(out)
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    webcamPlayer = player; webcamOutput = out
                } else { webcamPlayer = nil; webcamOutput = nil }
            }
        }

        private func render() {
            configureIfNeeded()
            guard let view, let player = mainPlayer else { return }

            // Audio
            player.volume = Float(model.isMuted ? 0 : model.volume)

            // Clock
            if model.isPlaying {
                let target = CMTime(seconds: model.currentTime, preferredTimescale: 600)
                if player.timeControlStatus != .playing {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                    webcamPlayer?.seek(to: target)
                    webcamPlayer?.play()
                } else if abs(model.currentTime - lastClockWriteback) > 0.1 {
                    // currentTime changed externally during playback (scrub/seek) → re-seek the clock.
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    webcamPlayer?.seek(to: target)
                }
                let t = CMTimeGetSeconds(player.currentTime())
                model.currentTime = t
                lastClockWriteback = t
                if t >= model.duration, model.duration > 0 {
                    model.pause(); player.pause(); webcamPlayer?.pause()
                }
            } else {
                if player.timeControlStatus == .playing { player.pause(); webcamPlayer?.pause() }
                let target = CMTime(seconds: model.currentTime, preferredTimescale: 600)
                if abs(CMTimeGetSeconds(player.currentTime()) - model.currentTime) > 0.033 {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    webcamPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }

            // Pull latest pixel buffers (cheap, retained refs). The expensive
            // CIImage→CGImage conversion happens off-main in the render block.
            let itemTime = player.currentTime()
            if let out = mainOutput, out.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                lastMainBuffer = pb
            }
            if let out = webcamOutput, let wp = webcamPlayer, out.hasNewPixelBuffer(forItemTime: wp.currentTime()),
               let pb = out.copyPixelBuffer(forItemTime: wp.currentTime(), itemTimeForDisplay: nil) {
                lastWebcamBuffer = pb
            }
            guard let mainBuf = lastMainBuffer else { return }
            // Drop only if a composite is already running (don't queue a backlog).
            if renderInFlight { return }
            renderInFlight = true
            // Capture everything from the @MainActor model HERE, on main.
            let sceneModel = model.sceneModel
            let t = model.currentTime
            let bg = model.backgroundImage
            let cursors = model.cursorBitmaps
            let dims = Geometry.exportDimensions(resolution: "1080p", aspectRatio: model.aspectRatio)
            let webcamBuf = lastWebcamBuffer
            let ctx = ciContext
            renderQueue.async { [weak self] in
                guard let main = Self.cgImage(from: mainBuf, ctx) else {
                    DispatchQueue.main.async { self?.renderInFlight = false }; return
                }
                let webcam = webcamBuf.flatMap { Self.cgImage(from: $0, ctx) }
                let inputs = SceneFrameInputs(mainVideo: main, webcamVideo: webcam,
                                              backgroundImage: bg, cursorBitmaps: cursors)
                let img = SceneRenderer.renderImage(model: sceneModel, inputs: inputs, currentTime: t, outputSize: dims)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let img {
                        // Snap contents with no implicit animation (avoids inter-frame fade).
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.view?.layer?.contents = img
                        CATransaction.commit()
                    }
                    self.renderInFlight = false
                }
            }
        }

        private static func cgImage(from pb: CVPixelBuffer, _ ctx: CIContext) -> CGImage? {
            let ci = CIImage(cvPixelBuffer: pb)
            return ctx.createCGImage(ci, from: ci.extent)
        }
    }
}

final class PreviewNSView: NSView {
    override var isFlipped: Bool { true }
}
