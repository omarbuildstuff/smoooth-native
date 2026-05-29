import Foundation
import AVFoundation

/// Records the webcam to its **own** `.mp4`, independent of the screen capture —
/// faithful to the Electron app, which produced a separate `*-webcam.mp4`
/// (recording-manager.ts `webcamVideoPath`). Uses an `AVCaptureSession` with an
/// `AVCaptureDevice` camera and `AVCaptureMovieFileOutput` (H.264). Also
/// enumerates cameras and microphones for the device pickers.
///
/// `@unchecked Sendable`: session mutation happens on `sessionQueue`; the
/// completion is delivered via a continuation.
public final class WebcamRecorder: NSObject, @unchecked Sendable {

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    /// Parallel data output used only to detect when the camera has warmed up
    /// (delivered its first frame), so the coordinator can start all recorders
    /// together after a pre-warm countdown.
    private let dataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.smoooth.webcam.session")
    private let dataQueue = DispatchQueue(label: "com.smoooth.webcam.data")
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<URL, Error>?

    private let stateLock = NSLock()
    private var _ready = false
    /// True once the camera has delivered its first frame (warmed up).
    public var isReady: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _ready }

    public override init() {
        super.init()
    }

    // MARK: - Device enumeration

    /// Lists connected cameras for the picker (replaces avfoundation device
    /// listing). The first device is flagged as default.
    public static func availableCameras() -> [CaptureDeviceInfo] {
        devices(mediaType: .video, deviceTypes: [
            .builtInWideAngleCamera,
            .external,
            .deskViewCamera,
        ])
    }

    /// Lists connected microphones for the picker.
    public static func availableMicrophones() -> [CaptureDeviceInfo] {
        devices(mediaType: .audio, deviceTypes: [
            .microphone,
            .external,
        ])
    }

    private static func devices(mediaType: AVMediaType, deviceTypes: [AVCaptureDevice.DeviceType]) -> [CaptureDeviceInfo] {
        // Filter to the device types actually valid for this media type to avoid
        // a runtime "unsupported device type" exception across OS versions.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: mediaType,
            position: .unspecified
        )
        let defaultID = AVCaptureDevice.default(for: mediaType)?.uniqueID
        return session.devices.map { device in
            CaptureDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID
            )
        }
    }

    // MARK: - Recording

    /// Pre-warms the camera: configures the session and starts it RUNNING, but does
    /// not write a file yet. `isReady` flips true on the first delivered frame, so
    /// the coordinator can wait for warmup before starting all recorders together.
    public func prewarm(cameraDeviceID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(cameraDeviceID: cameraDeviceID)
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Begins writing the webcam file. Call after `prewarm`, in lockstep with the
    /// screen recorder's `arm()`, so both files start at ~the same instant (the
    /// camera is already warm, so its first written frame is immediate).
    public func beginRecording(outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                try? FileManager.default.removeItem(at: outputURL)
                self.outputURL = outputURL
                self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
                continuation.resume()
            }
        }
    }

    /// Stops recording, finalizes the file, and returns its URL.
    @discardableResult
    public func stop() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            sessionQueue.async {
                guard self.movieOutput.isRecording else {
                    if let url = self.outputURL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: RecordingError.notRecording)
                    }
                    return
                }
                self.finishContinuation = continuation
                self.movieOutput.stopRecording()
            }
        }
    }

    /// Best-effort teardown discarding the partial file (used by `cancel()`).
    public func abort() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            if let url = self.outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            self.finishContinuation = nil
        }
    }

    // MARK: - Session configuration

    private func configureSession(cameraDeviceID: String?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        // Remove any prior inputs/outputs to allow reconfiguration.
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        let camera: AVCaptureDevice?
        if let cameraDeviceID, let device = AVCaptureDevice(uniqueID: cameraDeviceID) {
            camera = device
        } else {
            camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video)
        }
        guard let camera else {
            throw RecordingError.cameraPermissionDenied
        }

        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(videoInput) else {
            throw RecordingError.writerSetupFailed("cannot add camera input")
        }
        session.addInput(videoInput)

        guard session.canAddOutput(movieOutput) else {
            throw RecordingError.writerSetupFailed("cannot add movie output")
        }
        session.addOutput(movieOutput)

        // Readiness probe (non-fatal if unavailable).
        if session.canAddOutput(dataOutput) {
            dataOutput.alwaysDiscardsLateVideoFrames = true
            dataOutput.setSampleBufferDelegate(self, queue: dataQueue)
            session.addOutput(dataOutput)
        }

        // AVCaptureMovieFileOutput defaults to H.264 in a QuickTime container on
        // macOS, which the editor reads fine. Explicit per-connection codec
        // selection differs across SDKs (the no-arg `availableVideoCodecTypes`
        // is unavailable on macOS), so we rely on the default here.
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (readiness probe)

extension WebcamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        stateLock.lock(); _ready = true; stateLock.unlock()
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension WebcamRecorder: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: Error?) {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            let continuation = self.finishContinuation
            self.finishContinuation = nil
            if let error {
                // AVFoundation may report a "stopped" error that still produced a
                // valid file; treat a non-empty file as success.
                let attrs = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)
                let size = (attrs?[.size] as? Int) ?? 0
                if size > 0 {
                    continuation?.resume(returning: outputFileURL)
                } else {
                    continuation?.resume(throwing: error)
                }
                return
            }
            continuation?.resume(returning: outputFileURL)
        }
    }
}
