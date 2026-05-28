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
        private var timer: Timer?
        private var configuredVideoURL: URL?
        private var configuredWebcamURL: URL?
        private var lastMain: CGImage?
        private var lastWebcam: CGImage?
        private var lastClockWriteback: Double = -1
        private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        init(model: EditorModel) { self.model = model }

        func attach(to view: PreviewNSView) {
            self.view = view
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
        }

        func teardown() {
            timer?.invalidate(); timer = nil
            mainPlayer?.pause(); webcamPlayer?.pause()
        }

        func configureIfNeeded() {
            if model.videoURL != configuredVideoURL {
                configuredVideoURL = model.videoURL
                lastMain = nil
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
                lastWebcam = nil
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

            let itemTime = player.currentTime()
            if let out = mainOutput, out.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                lastMain = cgImage(from: pb)
            }
            if let out = webcamOutput, let wp = webcamPlayer, out.hasNewPixelBuffer(forItemTime: wp.currentTime()),
               let pb = out.copyPixelBuffer(forItemTime: wp.currentTime(), itemTimeForDisplay: nil) {
                lastWebcam = cgImage(from: pb)
            }
            guard let main = lastMain else { return }

            let dims = Geometry.exportDimensions(resolution: "720p", aspectRatio: model.aspectRatio)
            let inputs = SceneFrameInputs(mainVideo: main, webcamVideo: lastWebcam,
                                          backgroundImage: model.backgroundImage, cursorBitmaps: model.cursorBitmaps)
            if let img = SceneRenderer.renderImage(model: model.sceneModel, inputs: inputs,
                                                   currentTime: model.currentTime, outputSize: dims) {
                view.layer?.contents = img
            }
        }

        private func cgImage(from pb: CVPixelBuffer) -> CGImage? {
            let ci = CIImage(cvPixelBuffer: pb)
            return ciContext.createCGImage(ci, from: ci.extent)
        }
    }
}

final class PreviewNSView: NSView {
    override var isFlipped: Bool { true }
}
