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
                    mainPlayer = p; mainOutput = out
                    // Dedicated audio player on the same file, used ONLY when the user
                    // applies a non-zero audioOffset. By default the main player
                    // carries the audio (sample-locked to the screen video).
                    let aItem = AVPlayerItem(url: url)
                    let ap = AVPlayer(playerItem: aItem); ap.actionAtItemEnd = .pause; ap.isMuted = true
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

            // ONE master clock. The main player carries screen video AND audio,
            // sample-locked together. The webcam (separate file, late due to camera
            // warmup) and an optional offset-audio player are SLAVED to the master
            // and only re-seeked when they drift past a small threshold — nothing
            // free-runs on its own clock, so sync can't wander.
            let useOffsetAudio = abs(model.audioOffset) >= 0.001
            player.isMuted = useOffsetAudio ? true : model.isMuted
            player.volume = Float(model.isMuted ? 0 : model.volume)
            audioPlayer?.isMuted = useOffsetAudio ? model.isMuted : true
            audioPlayer?.volume = Float(model.isMuted ? 0 : model.volume)

            let wcActive = (model.currentTime - model.webcamOffset) >= 0

            func seekTime(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 600) }

            if model.isPlaying {
                if player.timeControlStatus != .playing {
                    player.seek(to: seekTime(model.currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                }
                let masterT = CMTimeGetSeconds(player.currentTime())

                // Offset audio (only when audioOffset != 0): slave to master − offset,
                // loose threshold so corrections don't glitch the audio.
                if useOffsetAudio, let ap = audioPlayer {
                    let want = masterT - model.audioOffset
                    if ap.timeControlStatus != .playing {
                        ap.seek(to: seekTime(want), toleranceBefore: .zero, toleranceAfter: .zero); ap.play()
                    } else if abs(CMTimeGetSeconds(ap.currentTime()) - want) > 0.12 {
                        ap.seek(to: seekTime(want), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                } else if let ap = audioPlayer, ap.timeControlStatus == .playing {
                    ap.pause()
                }

                // Webcam: slave to master − webcamOffset, tight ~1-frame threshold.
                if let wp = webcamPlayer {
                    if wcActive {
                        let want = masterT - model.webcamOffset
                        if wp.timeControlStatus != .playing {
                            wp.seek(to: seekTime(want), toleranceBefore: .zero, toleranceAfter: .zero); wp.play()
                        } else if abs(CMTimeGetSeconds(wp.currentTime()) - want) > 0.04 {
                            wp.seek(to: seekTime(want), toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    } else if wp.timeControlStatus == .playing {
                        wp.pause()
                    }
                }

                model.currentTime = masterT; lastClockWriteback = masterT
                if masterT >= model.duration, model.duration > 0 {
                    model.pause(); player.pause(); audioPlayer?.pause(); webcamPlayer?.pause()
                }
            } else {
                if player.timeControlStatus == .playing { player.pause(); audioPlayer?.pause(); webcamPlayer?.pause() }
                let mt = model.currentTime
                if abs(CMTimeGetSeconds(player.currentTime()) - mt) > 0.033 {
                    player.seek(to: seekTime(mt), toleranceBefore: .zero, toleranceAfter: .zero)
                    if useOffsetAudio { audioPlayer?.seek(to: seekTime(mt - model.audioOffset), toleranceBefore: .zero, toleranceAfter: .zero) }
                    webcamPlayer?.seek(to: seekTime(mt - model.webcamOffset), toleranceBefore: .zero, toleranceAfter: .zero)
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
