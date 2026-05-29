import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreGraphics
import SmooothCore

/// Live preview. Composites each frame with `SceneRenderer` — the SAME compositor
/// the exporter uses — so the preview is guaranteed identical to the export
/// (cursor placement, zoom, webcam, orientation). Rendering runs off the main
/// thread on a `CADisplayLink` tick at the view's display size (not a fixed 1080p),
/// which keeps it smooth; the composited CGImage is swapped onto the layer with no
/// implicit animation.
struct LayerPreview: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> PreviewLayerView {
        let v = PreviewLayerView()
        context.coordinator.attach(to: v)
        return v
    }
    func updateNSView(_ nsView: PreviewLayerView, context: Context) {}
    static func dismantleNSView(_ nsView: PreviewLayerView, coordinator: Coordinator) { coordinator.teardown() }

    @MainActor
    final class Coordinator {
        private let model: EditorModel
        private weak var view: PreviewLayerView?
        private var link: CADisplayLink?

        private var mainPlayer: AVPlayer?
        private var mainOutput: AVPlayerItemVideoOutput?
        /// Audio plays from a dedicated player (main video player is muted) so it
        /// can be shifted independently by `audioOffset` for manual A/V re-sync.
        private var audioPlayer: AVPlayer?
        private var webcamPlayer: AVPlayer?
        private var webcamOutput: AVPlayerItemVideoOutput?
        private var cfgVideoURL: URL?
        private var cfgWebcamURL: URL?
        private var lastClockWriteback = -1.0

        private var lastMainBuffer: CVPixelBuffer?
        private var lastWebcamBuffer: CVPixelBuffer?
        private var renderInFlight = false
        private let renderQueue = DispatchQueue(label: "com.smoooth.preview", qos: .userInteractive)
        private let ci = CIContext(options: [.useSoftwareRenderer: false])

        init(model: EditorModel) { self.model = model }

        func attach(to v: PreviewLayerView) {
            view = v
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.cgColor
            v.layer?.contentsGravity = .resizeAspect
            let dl = v.displayLink(target: self, selector: #selector(tick))
            dl.add(to: .main, forMode: .common)
            link = dl
        }

        func teardown() { link?.invalidate(); link = nil; mainPlayer?.pause(); audioPlayer?.pause(); webcamPlayer?.pause() }

        @objc private func tick() { render() }

        private func configurePlayers() {
            if model.videoURL != cfgVideoURL {
                cfgVideoURL = model.videoURL; lastMainBuffer = nil
                if let url = model.videoURL {
                    let item = AVPlayerItem(url: url)
                    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(out); let p = AVPlayer(playerItem: item); p.actionAtItemEnd = .pause
                    p.isMuted = true // audio comes from the dedicated audioPlayer
                    mainPlayer = p; mainOutput = out
                    // Separate audio player on the same file, shiftable by audioOffset.
                    let aItem = AVPlayerItem(url: url)
                    let ap = AVPlayer(playerItem: aItem); ap.actionAtItemEnd = .pause
                    audioPlayer = ap
                } else { mainPlayer = nil; mainOutput = nil; audioPlayer = nil }
            }
            if model.webcamVideoURL != cfgWebcamURL {
                cfgWebcamURL = model.webcamVideoURL; lastWebcamBuffer = nil
                if let url = model.webcamVideoURL {
                    let item = AVPlayerItem(url: url)
                    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(out); let p = AVPlayer(playerItem: item); p.isMuted = true
                    webcamPlayer = p; webcamOutput = out
                } else { webcamPlayer = nil; webcamOutput = nil }
            }
        }

        private func render() {
            configurePlayers()
            guard let view, let player = mainPlayer else { return }
            audioPlayer?.volume = Float(model.isMuted ? 0 : model.volume)

            // Clock. Three streams share one playhead `t` (driven by the main video
            // player) but each runs at its own offset: audio at `t − audioOffset`
            // and webcam at `t − webcamOffset`. Before the webcam offset there is no
            // camera footage yet, so it stays hidden.
            let wcSeconds = model.currentTime - model.webcamOffset
            let wcActive = wcSeconds >= 0
            let wcTarget = CMTime(seconds: max(0, wcSeconds), preferredTimescale: 600)
            let auTarget = CMTime(seconds: max(0, model.currentTime - model.audioOffset), preferredTimescale: 600)
            let resync = abs(model.currentTime - lastClockWriteback) > 0.1
            if model.isPlaying {
                let target = CMTime(seconds: model.currentTime, preferredTimescale: 600)
                if player.timeControlStatus != .playing {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero); player.play()
                } else if resync {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if let ap = audioPlayer {
                    if ap.timeControlStatus != .playing {
                        ap.seek(to: auTarget, toleranceBefore: .zero, toleranceAfter: .zero); ap.play()
                    } else if resync {
                        ap.seek(to: auTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                if let wp = webcamPlayer {
                    if wcActive {
                        if wp.timeControlStatus != .playing {
                            wp.seek(to: wcTarget, toleranceBefore: .zero, toleranceAfter: .zero); wp.play()
                        } else if resync {
                            wp.seek(to: wcTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    } else if wp.timeControlStatus == .playing {
                        wp.pause()
                    }
                }
                let t = CMTimeGetSeconds(player.currentTime())
                model.currentTime = t; lastClockWriteback = t
                if t >= model.duration, model.duration > 0 { model.pause(); player.pause(); audioPlayer?.pause(); webcamPlayer?.pause() }
            } else {
                if player.timeControlStatus == .playing { player.pause(); audioPlayer?.pause(); webcamPlayer?.pause() }
                let target = CMTime(seconds: model.currentTime, preferredTimescale: 600)
                if abs(CMTimeGetSeconds(player.currentTime()) - model.currentTime) > 0.033 {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    audioPlayer?.seek(to: auTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                    webcamPlayer?.seek(to: wcTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }

            // Latest frames (cheap retained refs; convert off-main).
            let itemTime = player.currentTime()
            if let out = mainOutput, out.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) { lastMainBuffer = pb }
            if wcActive, let out = webcamOutput, let wp = webcamPlayer, out.hasNewPixelBuffer(forItemTime: wp.currentTime()),
               let pb = out.copyPixelBuffer(forItemTime: wp.currentTime(), itemTimeForDisplay: nil) { lastWebcamBuffer = pb }
            if !wcActive { lastWebcamBuffer = nil }
            guard let mainBuf = lastMainBuffer else { return }
            if renderInFlight { return }
            renderInFlight = true

            // Output at the view's display size (capped), driven by the chosen aspect.
            let scale = view.window?.backingScaleFactor ?? 2
            let comps = model.aspectRatio.components
            let viewWpx = max(2, view.bounds.width * scale)
            let viewHpx = max(2, view.bounds.height * scale)
            let ar = comps.w / comps.h
            var outW = viewWpx, outH = viewWpx / ar
            if outH > viewHpx { outH = viewHpx; outW = viewHpx * ar }
            // Cap so the CPU composite stays well under the frame interval — a slow
            // composite makes the displayed video lag the real-time audio clock.
            // Preview only; export renders at full resolution.
            let cap = 720.0
            if outW > cap { outH *= cap / outW; outW = cap }
            let dims = SizeI(width: max(2, Int(outW.rounded())), height: max(2, Int(outH.rounded())))

            let sceneModel = model.sceneModel
            let t = model.currentTime
            let bg = model.backgroundImage
            let cursors = model.cursorBitmaps
            let custom = model.customCursor
            let mainBufRef = mainBuf
            let webcamBufRef = lastWebcamBuffer
            let ctx = ci

            renderQueue.async { [weak self] in
                let main = Self.cg(mainBufRef, ctx)
                let webcam = webcamBufRef.flatMap { Self.cg($0, ctx) }
                guard let main else { DispatchQueue.main.async { self?.renderInFlight = false }; return }
                let inputs = SceneFrameInputs(mainVideo: main, webcamVideo: webcam,
                                              backgroundImage: bg, cursorBitmaps: cursors, customCursor: custom)
                let img = SceneRenderer.renderImage(model: sceneModel, inputs: inputs, currentTime: t, outputSize: dims)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let img {
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        self.view?.layer?.contents = img
                        CATransaction.commit()
                    }
                    self.renderInFlight = false
                }
            }
        }

        private static func cg(_ pb: CVPixelBuffer, _ ctx: CIContext) -> CGImage? {
            let img = CIImage(cvPixelBuffer: pb)
            return ctx.createCGImage(img, from: img.extent)
        }
    }
}

final class PreviewLayerView: NSView {
    override var isFlipped: Bool { true }
}
