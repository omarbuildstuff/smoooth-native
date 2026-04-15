import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Combine

/// Queries TCC state for the permissions the app needs. Publishes changes for SwiftUI consumers.
@MainActor
final class PermissionsChecker: ObservableObject {
    @Published var hasScreenRecording: Bool = false
    @Published var hasAccessibility: Bool = false
    @Published var hasMicrophone: Bool = false
    @Published var hasCamera: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasCamera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: - Requests

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        // This function prompts the user and adds the app to System Settings on first call.
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)

        // Also open System Settings directly — it's the reliable path.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
