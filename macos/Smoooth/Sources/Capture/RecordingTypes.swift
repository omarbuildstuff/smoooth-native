import Foundation
import CoreGraphics

// Capture engine value types. These mirror the recording options and results the
// Electron app exchanged over IPC (electron/main/ipc/handlers/recording.ts,
// desktop.ts) and the metadata JSON the editor consumes
// (src/types/index.ts MetaDataItem, recording-manager.ts processAndSaveMetadata).

// MARK: - Recording source

/// What the user chose to capture. Faithful to the original `source` option
/// ('fullscreen' | 'area' | 'window') plus the resolved target.
public enum RecordingSource: Equatable, Sendable {
    /// Capture an entire display. `displayID` is a `CGDirectDisplayID`; when nil
    /// the main display is used (mirrors `screen.getPrimaryDisplay()`).
    case fullscreen(displayID: CGDirectDisplayID?)
    /// Capture a sub-region of a display, in that display's points (top-left
    /// origin, matching the selection window). Converted to physical pixels and
    /// even-sized internally, exactly like the Electron `area` path.
    case area(displayID: CGDirectDisplayID?, rect: CGRect)
    /// Capture a single window by its `CGWindowID`.
    case window(windowID: CGWindowID)
}

// MARK: - Device selection

/// A capture device (camera or microphone) surfaced to the picker UI. The
/// `uniqueID` is an `AVCaptureDevice.uniqueID`, stable across launches.
public struct CaptureDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: String           // AVCaptureDevice.uniqueID
    public let name: String         // localizedName
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    public var uniqueID: String { id }
}

/// Enumerated cameras + microphones for the device pickers (replaces the
/// Electron `getDshowDevices`/avfoundation enumeration).
public struct AvailableDevices: Equatable, Sendable {
    public var cameras: [CaptureDeviceInfo]
    public var microphones: [CaptureDeviceInfo]

    public init(cameras: [CaptureDeviceInfo] = [], microphones: [CaptureDeviceInfo] = []) {
        self.cameras = cameras
        self.microphones = microphones
    }
}

// MARK: - Recording options

/// Everything the UI passes to `RecordingCoordinator.start`. Mirrors the
/// Electron start options: { source, displayId, mic, webcam, systemAudio }.
public struct RecordingOptions: Sendable {
    public var source: RecordingSource
    /// Capture the microphone. `microphoneDeviceID` selects a device; nil uses
    /// the system default input.
    public var microphone: Bool
    public var microphoneDeviceID: String?
    /// Capture the webcam to a separate file. `cameraDeviceID` selects a device;
    /// nil uses the default camera.
    public var webcam: Bool
    public var cameraDeviceID: String?
    /// Capture system (loopback) audio into the screen recording.
    public var systemAudio: Bool
    /// Frames per second target for the screen capture.
    public var fps: Int

    public init(source: RecordingSource,
                microphone: Bool = false,
                microphoneDeviceID: String? = nil,
                webcam: Bool = false,
                cameraDeviceID: String? = nil,
                systemAudio: Bool = false,
                fps: Int = 60) {
        self.source = source
        self.microphone = microphone
        self.microphoneDeviceID = microphoneDeviceID
        self.webcam = webcam
        self.cameraDeviceID = cameraDeviceID
        self.systemAudio = systemAudio
        self.fps = fps
    }
}

// MARK: - Geometry

/// The recording geometry in **physical pixels** with an even width/height,
/// computed via the display's scale factor — the exact contract from
/// recording-manager.ts (Fix #135). The editor maps cursor coordinates against
/// this rect.
public struct RecordingGeometry: Equatable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

// MARK: - Result

/// Output of a finished recording. Carries the screen video, optional webcam
/// video, and the metadata JSON — the three artifacts the editor loads
/// (mirrors `createEditorWindow(screenVideoPath, metadataPath, geometry, webcamVideoPath)`).
public struct RecordingResult: Sendable {
    public var screenVideoURL: URL
    public var webcamVideoURL: URL?
    public var metadataURL: URL
    public var geometry: RecordingGeometry

    public init(screenVideoURL: URL, webcamVideoURL: URL?, metadataURL: URL, geometry: RecordingGeometry) {
        self.screenVideoURL = screenVideoURL
        self.webcamVideoURL = webcamVideoURL
        self.metadataURL = metadataURL
        self.geometry = geometry
    }
}

// MARK: - Errors

public enum RecordingError: LocalizedError {
    case screenPermissionDenied
    case microphonePermissionDenied
    case cameraPermissionDenied
    case accessibilityPermissionDenied
    case noDisplayAvailable
    case noWindowAvailable
    case alreadyRecording
    case notRecording
    case writerSetupFailed(String)
    case captureStartFailed(String)
    case emptyOutput(String)

    public var errorDescription: String? {
        switch self {
        case .screenPermissionDenied:
            return "Smoooth needs Screen Recording permission to record your screen."
        case .microphonePermissionDenied:
            return "Microphone permission is required to record audio."
        case .cameraPermissionDenied:
            return "Camera permission is required to record the webcam."
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required to capture mouse clicks."
        case .noDisplayAvailable:
            return "No display was available to record."
        case .noWindowAvailable:
            return "The selected window is no longer available."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "There is no active recording to stop."
        case .writerSetupFailed(let detail):
            return "Failed to set up the video writer: \(detail)"
        case .captureStartFailed(let detail):
            return "Failed to start screen capture: \(detail)"
        case .emptyOutput(let name):
            return "The recording produced an empty file (\(name))."
        }
    }
}
