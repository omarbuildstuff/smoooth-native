import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import ApplicationServices

/// Centralizes the four permissions the capture engine needs, mirroring the
/// permission checks scattered across recording-manager.ts / desktop.ts:
///   - Screen Recording  (probed via SCShareableContent, like the Electron
///     `desktopCapturer.getSources` probe — getMediaAccessStatus('screen') is
///     unreliable on macOS 14+).
///   - Microphone / Camera (AVCaptureDevice authorization).
///   - Accessibility (for the CGEventTap used to capture clicks).
///
/// Marked `@unchecked Sendable` because it is stateless; all calls are safe to
/// make from any actor.
public final class PermissionsManager: @unchecked Sendable {
    public init() {}

    // MARK: - Status enum

    public enum Status: Sendable {
        case granted
        case denied
        case notDetermined
    }

    // MARK: - Screen Recording

    /// Probe Screen Recording by attempting to enumerate shareable content.
    /// On denial macOS returns an error / empty content, exactly the signal the
    /// Electron app used (`sources.length > 0`).
    public func screenRecordingStatus() async -> Status {
        // CGPreflightScreenCaptureAccess is the cheap, synchronous probe added in
        // macOS 11+. It does not prompt. Trust it as the primary signal.
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        // Fall back to an SCShareableContent probe: if we can list displays we
        // effectively have access (covers edge cases where the preflight lags
        // behind a freshly granted permission).
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return content.displays.isEmpty ? .denied : .granted
        } catch {
            return .denied
        }
    }

    /// Triggers the system Screen Recording prompt (first launch) via the
    /// CoreGraphics request API. Returns whether access ended up granted.
    @discardableResult
    public func requestScreenRecording() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Fires the TCC prompt the first time; subsequent calls are a no-op and
        // the user must toggle the setting manually.
        let granted = CGRequestScreenCaptureAccess()
        if granted { return true }
        return await screenRecordingStatus() == .granted
    }

    // MARK: - Camera / Microphone

    public func cameraStatus() -> Status {
        map(AVCaptureDevice.authorizationStatus(for: .video))
    }

    public func microphoneStatus() -> Status {
        map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Requests camera access, prompting when not-determined (mirrors
    /// `systemPreferences.askForMediaAccess('camera')`).
    public func requestCamera() async -> Bool {
        await requestMedia(.video)
    }

    /// Requests microphone access, prompting when not-determined.
    public func requestMicrophone() async -> Bool {
        await requestMedia(.audio)
    }

    private func requestMedia(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: type) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: - Accessibility (CGEventTap)

    /// Accessibility status for the CGEventTap. The tap also degrades gracefully
    /// to NSEvent global monitors, but those need this grant too.
    public func accessibilityStatus() -> Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Like `accessibilityStatus`, but pops the system "grant Accessibility"
    /// prompt the first time when `prompt` is true.
    @discardableResult
    public func requestAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Opening System Settings panes

    public enum SettingsPane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
        case camera = "Privacy_Camera"
        case accessibility = "Privacy_Accessibility"
    }

    /// Opens the relevant Privacy & Security pane, matching the
    /// `x-apple.systempreferences:` URLs the Electron app used.
    public func openSettings(_ pane: SettingsPane) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func map(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
