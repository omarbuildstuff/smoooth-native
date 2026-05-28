import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit
import SmooothCore

/// Top-level capture orchestrator the UI talks to — the native replacement for
/// the Electron recording-manager's `startRecording` / `stopRecording` /
/// `cancelRecording` flow. It:
///   - enumerates capture devices for the pickers,
///   - computes the physical-pixel, even-sized `RecordingGeometry`
///     (Fix #135 parity),
///   - gates on the required permissions,
///   - drives `ScreenRecorder` (+ optional `WebcamRecorder`) and `MouseTracker`,
///   - on stop, writes the metadata JSON and returns a `RecordingResult`.
///
/// Files land under Application Support `Smoooth/recordings/`, named
/// `Smoooth-recording-<epochMillis>-screen.mp4` / `-webcam.mp4` / `.json`,
/// matching the original naming so cleanup/import patterns stay compatible.
@MainActor
public final class RecordingCoordinator: ObservableObject {

    // MARK: - Observable state

    public enum State: Equatable {
        case idle
        case preparing
        case recording
        case stopping
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var availableDevices = AvailableDevices()
    @Published public private(set) var lastError: String?

    // MARK: - Collaborators

    public let permissions: PermissionsManager

    private var screenRecorder: ScreenRecorder?
    private var webcamRecorder: WebcamRecorder?
    private var mouseTracker: MouseTracker?

    private var activeGeometry: RecordingGeometry?
    private var activeScreenURL: URL?
    private var activeWebcamURL: URL?
    private var activeMetadataURL: URL?

    public init(permissions: PermissionsManager = PermissionsManager()) {
        self.permissions = permissions
    }

    // MARK: - Device enumeration

    /// Refreshes the camera + microphone lists (call before showing pickers).
    @discardableResult
    public func enumerateDevices() -> AvailableDevices {
        let devices = AvailableDevices(
            cameras: WebcamRecorder.availableCameras(),
            microphones: WebcamRecorder.availableMicrophones()
        )
        availableDevices = devices
        return devices
    }

    // MARK: - Start

    /// Begins a recording from the given options. Performs permission checks,
    /// resolves geometry, then starts the screen recorder, optional webcam
    /// recorder, and the mouse tracker. Throws (and resets to `.idle`) on any
    /// failure, mirroring the Electron `{ canceled: true }` early returns.
    public func start(options: RecordingOptions) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        state = .preparing
        lastError = nil

        do {
            try await preflightPermissions(options: options)

            let geometry = try await resolveGeometry(for: options.source)
            let screenSource = normalizedSource(options.source, geometry: geometry)

            let urls = makeOutputURLs(hasWebcam: options.webcam)
            try ensureRecordingDirectoryExists()

            // --- Mouse tracker first, so we don't miss early events. ---
            let tracker = MouseTracker()
            guard tracker.start() else {
                throw RecordingError.accessibilityPermissionDenied
            }
            self.mouseTracker = tracker

            // --- Screen recorder. ---
            let recorder = ScreenRecorder(
                outputURL: urls.screen,
                geometry: geometry,
                systemAudio: options.systemAudio,
                microphone: options.microphone,
                fps: options.fps
            )
            do {
                try await recorder.start(source: screenSource)
            } catch {
                tracker.stop()
                self.mouseTracker = nil
                throw error
            }
            self.screenRecorder = recorder

            // --- Webcam recorder (separate file). ---
            if options.webcam, let webcamURL = urls.webcam {
                let webcam = WebcamRecorder()
                do {
                    try await webcam.start(cameraDeviceID: options.cameraDeviceID, outputURL: webcamURL)
                    self.webcamRecorder = webcam
                    self.activeWebcamURL = webcamURL
                } catch {
                    // Non-fatal: keep the screen recording going without webcam,
                    // matching the original's tolerance of webcam failures.
                    webcam.abort()
                    self.webcamRecorder = nil
                    self.activeWebcamURL = nil
                }
            }

            self.activeGeometry = geometry
            self.activeScreenURL = urls.screen
            self.activeMetadataURL = urls.metadata
            state = .recording
        } catch {
            state = .idle
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    // MARK: - Stop

    /// Stops everything, writes metadata, and returns the artifacts. After this
    /// returns the coordinator is back to `.idle`.
    @discardableResult
    public func stop() async throws -> RecordingResult {
        guard state == .recording,
              let recorder = screenRecorder,
              let geometry = activeGeometry,
              let metadataURL = activeMetadataURL else {
            throw RecordingError.notRecording
        }
        state = .stopping

        // Stop the tracker before finalizing video so its sample stream is closed.
        let tracker = mouseTracker
        tracker?.stop()

        let screenURL: URL
        do {
            screenURL = try await recorder.stop()
        } catch {
            // Even on a writer error, attempt to clean up the rest.
            await finalizeWebcamSilently()
            resetActiveState()
            state = .idle
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }

        var webcamURL: URL? = nil
        if let webcam = webcamRecorder {
            webcamURL = try? await webcam.stop()
        }

        // Build + write metadata, rebasing timestamps to the first video frame.
        let drained = tracker?.drain() ?? (samples: [], cursors: [:])
        let metadata = RecordingMetadataWriter.build(
            samples: drained.samples,
            cursors: drained.cursors,
            geometry: geometry,
            screenSize: primaryScreenPixelSize(),
            videoStartWallClock: recorder.firstFrameWallClock
        )
        do {
            try metadata.write(to: metadataURL)
        } catch {
            // Write a minimal fallback so the editor doesn't crash (parity with
            // the Electron error path that writes empty metadata).
            let fallback = RecordingMetadataWriter(
                platform: "darwin",
                screenSize: primaryScreenPixelSize(),
                geometry: geometry,
                syncOffset: 0,
                cursorImages: [:],
                events: []
            )
            try? fallback.write(to: metadataURL)
        }

        let result = RecordingResult(
            screenVideoURL: screenURL,
            webcamVideoURL: webcamURL,
            metadataURL: metadataURL,
            geometry: geometry
        )

        resetActiveState()
        state = .idle
        return result
    }

    // MARK: - Cancel

    /// Aborts the recording and discards all partial files (parity with
    /// `cancelRecording` / `cleanupAndDiscard`).
    public func cancel() async {
        guard state == .recording || state == .preparing || state == .stopping else { return }

        mouseTracker?.stop()
        mouseTracker = nil

        if let recorder = screenRecorder {
            await recorder.abort()
        }
        webcamRecorder?.abort()

        // Remove any metadata that may have been written.
        if let metadataURL = activeMetadataURL {
            try? FileManager.default.removeItem(at: metadataURL)
        }

        resetActiveState()
        state = .idle
    }

    // MARK: - Permission preflight

    private func preflightPermissions(options: RecordingOptions) async throws {
        // Screen recording is always required.
        if await permissions.screenRecordingStatus() != .granted {
            _ = await permissions.requestScreenRecording()
            if await permissions.screenRecordingStatus() != .granted {
                throw RecordingError.screenPermissionDenied
            }
        }

        if options.microphone {
            if permissions.microphoneStatus() != .granted {
                let granted = await permissions.requestMicrophone()
                if !granted { throw RecordingError.microphonePermissionDenied }
            }
        }

        if options.webcam {
            if permissions.cameraStatus() != .granted {
                let granted = await permissions.requestCamera()
                if !granted { throw RecordingError.cameraPermissionDenied }
            }
        }

        // Accessibility is needed for the CGEventTap to capture clicks; the
        // tracker can still fall back to NSEvent monitors, so we only prompt
        // (non-fatal) rather than hard-fail here.
        if permissions.accessibilityStatus() != .granted {
            _ = permissions.requestAccessibility(prompt: true)
        }
    }

    // MARK: - Geometry resolution

    /// Computes the physical-pixel, even-sized geometry for a source. Replicates
    /// recording-manager.ts: physical pixels via scale factor, width/height
    /// floored to an even number.
    private func resolveGeometry(for source: RecordingSource) async throws -> RecordingGeometry {
        switch source {
        case .fullscreen(let displayID):
            let id = displayID ?? CGMainDisplayID()
            return try displayGeometry(id)

        case .area(let displayID, let rect):
            let id = displayID ?? CGMainDisplayID()
            let scale = scaleFactor(for: id)
            let x = Int((rect.origin.x * scale).rounded())
            let y = Int((rect.origin.y * scale).rounded())
            let w = evenFloor(rect.width * scale)
            let h = evenFloor(rect.height * scale)
            return RecordingGeometry(x: x, y: y, width: w, height: h)

        case .window:
            // For a window capture the geometry origin is 0,0 and the size is the
            // window's pixel size; SCKit handles the actual crop, but we still
            // need a stable rect for cursor mapping. Resolve from shareable
            // content's window frame.
            return try await windowGeometry(for: source)
        }
    }

    private func displayGeometry(_ displayID: CGDirectDisplayID) throws -> RecordingGeometry {
        let bounds = CGDisplayBounds(displayID)            // points, global, top-left
        guard bounds.width > 0, bounds.height > 0 else {
            throw RecordingError.noDisplayAvailable
        }
        let scale = scaleFactor(for: displayID)
        let x = Int((bounds.origin.x * scale).rounded())
        let y = Int((bounds.origin.y * scale).rounded())
        // CGDisplayPixelsWide/High return the actual backing-store pixel size.
        let pxW = CGDisplayPixelsWide(displayID)
        let pxH = CGDisplayPixelsHigh(displayID)
        let width = evenFloor(Double(pxW))
        let height = evenFloor(Double(pxH))
        return RecordingGeometry(x: x, y: y, width: width, height: height)
    }

    private func windowGeometry(for source: RecordingSource) async throws -> RecordingGeometry {
        guard case let .window(windowID) = source else {
            throw RecordingError.noWindowAvailable
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw RecordingError.noWindowAvailable
        }
        // Window frame is in points; scale by the display it sits on.
        let frame = window.frame
        let displayID = displayIDContaining(frame) ?? CGMainDisplayID()
        let scale = scaleFactor(for: displayID)
        let width = evenFloor(frame.width * scale)
        let height = evenFloor(frame.height * scale)
        // Origin 0,0: cursor coords are mapped relative to the window in the
        // editor, and SCKit crops to the window content.
        return RecordingGeometry(x: 0, y: 0, width: width, height: height)
    }

    /// For an area capture we pass the selection rect (in points) through to SCKit
    /// as `sourceRect`; the geometry already carries the pixel size. For other
    /// sources the source is unchanged.
    private func normalizedSource(_ source: RecordingSource, geometry: RecordingGeometry) -> RecordingSource {
        source
    }

    // MARK: - Display helpers

    private func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        if let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func displayIDContaining(_ frame: CGRect) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            if screen.frame.intersects(frame),
               let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return id
            }
        }
        return nil
    }

    /// Primary-display pixel size (what the original wrote into `screenSize`).
    private func primaryScreenPixelSize() -> SizeI {
        let id = CGMainDisplayID()
        return SizeI(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
    }

    private func evenFloor(_ value: Double) -> Int {
        Int((value / 2).rounded(.down)) * 2
    }

    // MARK: - File lifecycle

    private struct OutputURLs {
        let screen: URL
        let webcam: URL?
        let metadata: URL
    }

    private func makeOutputURLs(hasWebcam: Bool) -> OutputURLs {
        let dir = recordingsDirectory()
        let baseName = "Smoooth-recording-\(Int(Date().timeIntervalSince1970 * 1000))"
        return OutputURLs(
            screen: dir.appendingPathComponent("\(baseName)-screen.mp4"),
            webcam: hasWebcam ? dir.appendingPathComponent("\(baseName)-webcam.mp4") : nil,
            metadata: dir.appendingPathComponent("\(baseName).json")
        )
    }

    /// Application Support `Smoooth/recordings/`.
    public func recordingsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Smoooth", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }

    private func ensureRecordingDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: recordingsDirectory(),
            withIntermediateDirectories: true
        )
    }

    private func finalizeWebcamSilently() async {
        if let webcam = webcamRecorder {
            _ = try? await webcam.stop()
        }
    }

    private func resetActiveState() {
        screenRecorder = nil
        webcamRecorder = nil
        mouseTracker = nil
        activeGeometry = nil
        activeScreenURL = nil
        activeWebcamURL = nil
        activeMetadataURL = nil
    }
}
