import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Thin wrapper around SCStream that delivers screen (and optionally system audio) sample buffers
/// to a handler on a background queue. Handler must do minimal work — ideally just forward to the
/// asset writer.
final class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    enum SourceKind {
        case display(SCDisplay)
        case window(SCWindow)
    }

    enum CaptureError: Error {
        case noContentFound
        case noDisplay
        case streamStartFailed(Error)
    }

    struct Configuration {
        var width: Int
        var height: Int
        var fps: Int32
        var captureAudio: Bool

        static func defaultFor(_ source: SourceKind, fps: Int32 = 60, audio: Bool = true) -> Configuration {
            switch source {
            case .display(let d):
                return Configuration(width: d.width * 2, height: d.height * 2, fps: fps, captureAudio: audio)
            case .window(let w):
                let w_i = max(1, Int(w.frame.width))
                let h_i = max(1, Int(w.frame.height))
                return Configuration(width: w_i, height: h_i, fps: fps, captureAudio: audio)
            }
        }
    }

    // MARK: - Callbacks

    /// Called on a background queue for every screen frame.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Called on a background queue for every audio sample buffer (if audio enabled).
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Called (on a background queue) when the stream stops with an error.
    var onStopError: ((Error) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.cursorful.capture.samples", qos: .userInteractive)
    private let audioQueue  = DispatchQueue(label: "com.cursorful.capture.audio",   qos: .userInteractive)

    // MARK: - Source discovery

    /// Fetch shareable content and return the active main display.
    static func primaryDisplay() async throws -> SCDisplay {
        let content = try await SCShareableContent.current
        guard let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        return main
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.current
    }

    // MARK: - Start / stop

    func start(source: SourceKind, config: Configuration) async throws {
        let filter: SCContentFilter
        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = config.width
        streamConfig.height = config.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: config.fps)
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 6
        streamConfig.showsCursor = false  // we render our own smoothed cursor at edit time
        streamConfig.capturesAudio = config.captureAudio

        if #available(macOS 14.0, *) {
            streamConfig.colorSpaceName = CGColorSpace.sRGB
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if config.captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        try await stream.startCapture()
        Log.capture.info("SCStream started \(config.width)x\(config.height) @ \(config.fps)fps")
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            Log.capture.info("SCStream stopped")
        } catch {
            Log.capture.error("SCStream stop error: \(error.localizedDescription)")
        }
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        // Filter frames that are not ready (SCK sends status updates as attachments).
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        if let first = attachments?.first,
           let statusRaw = first[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }
        switch type {
        case .screen: onVideoSampleBuffer?(sampleBuffer)
        case .audio:  onAudioSampleBuffer?(sampleBuffer)
        default: break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("SCStream stopped with error: \(error.localizedDescription)")
        onStopError?(error)
    }
}
