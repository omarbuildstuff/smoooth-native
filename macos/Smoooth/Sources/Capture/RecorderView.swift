import SwiftUI
import AppKit
import SmooothCore

/// Recorder setup: capture options + an up-front permissions checklist. Pressing
/// Record requests every required permission first, then hands off to the floating
/// HUD flow (`onStart`) which hides the main window and begins capture.
struct RecorderView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    var onStart: (RecordingOptions) -> Void
    var onBack: () -> Void

    @Environment(\.theme) private var theme

    @State private var captureSystemAudio = false
    @State private var captureMic = false
    @State private var captureWebcam = false
    @State private var micDeviceID: String?
    @State private var cameraDeviceID: String?
    @State private var fps = 60
    @State private var errorMessage: String?
    @State private var requesting = false

    @State private var screenStatus: PermissionsManager.Status = .notDetermined
    @State private var axStatus: PermissionsManager.Status = .notDetermined
    @State private var camStatus: PermissionsManager.Status = .notDetermined
    @State private var micStatus: PermissionsManager.Status = .notDetermined

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous).fill(theme.primary.opacity(0.12))
                        Image(systemName: "record.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.primary)
                    }.frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("New Recording").font(.system(size: 17, weight: .bold)).foregroundStyle(theme.foreground)
                        Text("Full screen · cinematic auto-zoom").font(.system(size: 11)).foregroundStyle(theme.mutedForeground)
                    }
                    Spacer()
                }

                optionsForm
                permissionsSection

                if let errorMessage {
                    Text(errorMessage).font(.system(size: 12)).foregroundStyle(theme.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Back") { onBack() }.buttonStyle(SoftButtonStyle(theme: theme))
                    Spacer()
                    Button { Task { await ensureAndStart() } } label: {
                        Label(requesting ? "Checking…" : "Record Full Screen", systemImage: "record.circle.fill").frame(width: 180)
                    }
                    .buttonStyle(PremiumButtonStyle(theme: theme, height: 40))
                    .disabled(requesting || coordinator.state != .idle)
                }
                .padding(.top, 2)
            }
            .padding(26)
            .frame(width: 480)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusXl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusXl, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 12)
        }
        .onAppear { coordinator.enumerateDevices(); Task { await refresh() } }
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelToggle(title: "System audio", isOn: $captureSystemAudio)
            PanelToggle(title: "Microphone", isOn: $captureMic)
            if captureMic {
                PanelRow(title: "Mic") {
                    Picker("", selection: $micDeviceID) {
                        Text("Default").tag(String?.none)
                        ForEach(coordinator.availableDevices.microphones) { Text($0.name).tag(String?.some($0.id)) }
                    }.labelsHidden().frame(width: 190)
                }
            }
            PanelToggle(title: "Webcam overlay", isOn: $captureWebcam)
            if captureWebcam {
                PanelRow(title: "Camera") {
                    Picker("", selection: $cameraDeviceID) {
                        Text("Default").tag(String?.none)
                        ForEach(coordinator.availableDevices.cameras) { Text($0.name).tag(String?.some($0.id)) }
                    }.labelsHidden().frame(width: 190)
                }
            }
            PanelRow(title: "Frame rate") {
                Picker("", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 150)
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PERMISSIONS").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(theme.mutedForeground)
            permRow("Screen Recording", "Required to capture the screen", screenStatus, .screenRecording, required: true)
            permRow("Accessibility", "Tracks clicks for auto-zoom", axStatus, .accessibility, required: false)
            if captureWebcam { permRow("Camera", "Webcam overlay", camStatus, .camera, required: false) }
            if captureMic { permRow("Microphone", "Voiceover audio", micStatus, .microphone, required: false) }
        }
        .padding(12)
        .background(theme.muted.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
    }

    @ViewBuilder
    private func permRow(_ title: String, _ subtitle: String, _ status: PermissionsManager.Status,
                         _ pane: PermissionsManager.SettingsPane, required: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.foreground)
                    if required {
                        Text("REQUIRED").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.primary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(theme.primary.opacity(0.14)).clipShape(Capsule())
                    }
                }
                Text(subtitle).font(.system(size: 10)).foregroundStyle(theme.mutedForeground)
            }
            Spacer()
            if status == .granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.success)
            } else {
                Button("Grant") { Task { await grant(pane); coordinator.permissions.openSettings(pane); await refresh() } }
                    .buttonStyle(SoftButtonStyle(theme: theme, height: 26))
            }
        }
    }

    // MARK: - Permission flow

    private func refresh() async {
        screenStatus = await coordinator.permissions.screenRecordingStatus()
        axStatus = coordinator.permissions.accessibilityStatus()
        camStatus = coordinator.permissions.cameraStatus()
        micStatus = coordinator.permissions.microphoneStatus()
    }

    private func grant(_ pane: PermissionsManager.SettingsPane) async {
        switch pane {
        case .screenRecording: _ = await coordinator.permissions.requestScreenRecording()
        case .accessibility: _ = coordinator.permissions.requestAccessibility(prompt: true)
        case .camera: _ = await coordinator.permissions.requestCamera()
        case .microphone: _ = await coordinator.permissions.requestMicrophone()
        }
    }

    /// Requests every relevant permission up front, then starts (or guides the user).
    private func ensureAndStart() async {
        requesting = true; errorMessage = nil
        if screenStatus != .granted { _ = await coordinator.permissions.requestScreenRecording() }
        _ = coordinator.permissions.requestAccessibility(prompt: true)
        if captureMic, micStatus != .granted { _ = await coordinator.permissions.requestMicrophone() }
        if captureWebcam, camStatus != .granted { _ = await coordinator.permissions.requestCamera() }
        await refresh()
        requesting = false

        guard screenStatus == .granted else {
            errorMessage = "Screen Recording permission is required. Enable Smoooth under System Settings → Privacy & Security → Screen Recording, then click Record again."
            coordinator.permissions.openSettings(.screenRecording)
            return
        }
        if axStatus != .granted {
            errorMessage = "Tip: grant Accessibility for click-accurate auto-zoom (recording will still work)."
        }
        onStart(RecordingOptions(source: .fullscreen(displayID: nil),
                                 microphone: captureMic, microphoneDeviceID: micDeviceID,
                                 webcam: captureWebcam, cameraDeviceID: cameraDeviceID,
                                 systemAudio: captureSystemAudio, fps: fps))
    }
}
