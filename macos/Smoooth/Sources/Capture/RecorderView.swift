import SwiftUI
import AppKit
import SmooothCore

/// The recorder control panel: choose what to capture, gate on permissions, then
/// drive RecordingCoordinator. On stop, hands the result back to load into the editor.
struct RecorderView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    var onFinished: (RecordingResult) -> Void
    var onCancel: () -> Void

    @Environment(\.theme) private var theme

    @State private var captureSystemAudio = false
    @State private var captureMic = false
    @State private var captureWebcam = false
    @State private var micDeviceID: String?
    @State private var cameraDeviceID: String?
    @State private var fps = 60
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous).fill(theme.primary.opacity(0.12))
                        Image(systemName: "record.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.primary)
                    }
                    .frame(width: 36, height: 36)
                    Text("New Recording").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.foreground)
                }

                if coordinator.state == .recording {
                    recordingControls
                } else {
                    optionsForm
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12)).foregroundStyle(theme.destructive)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
            .frame(width: 460)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusXl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusXl, style: .continuous).strokeBorder(theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 12)
        }
        .onAppear { coordinator.enumerateDevices() }
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelToggle(title: "System audio", isOn: $captureSystemAudio)
            PanelToggle(title: "Microphone", isOn: $captureMic)
            if captureMic {
                PanelRow(title: "Mic") {
                    Picker("", selection: $micDeviceID) {
                        Text("Default").tag(String?.none)
                        ForEach(coordinator.availableDevices.microphones) { Text($0.name).tag(String?.some($0.id)) }
                    }.labelsHidden().frame(width: 180)
                }
            }
            PanelToggle(title: "Webcam overlay", isOn: $captureWebcam)
            if captureWebcam {
                PanelRow(title: "Camera") {
                    Picker("", selection: $cameraDeviceID) {
                        Text("Default").tag(String?.none)
                        ForEach(coordinator.availableDevices.cameras) { Text($0.name).tag(String?.some($0.id)) }
                    }.labelsHidden().frame(width: 180)
                }
            }
            PanelRow(title: "Frame rate") {
                Picker("", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 160)
            }

            HStack {
                Button("Back") { onCancel() }
                    .buttonStyle(SoftButtonStyle(theme: theme))
                Spacer()
                Button {
                    Task { await startRecording() }
                } label: {
                    Label("Record Full Screen", systemImage: "record.circle")
                }
                .buttonStyle(PremiumButtonStyle(theme: theme))
                .disabled(coordinator.state != .idle)
                .opacity(coordinator.state != .idle ? 0.5 : 1)
            }
            .padding(.top, 4)
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(theme.destructive).frame(width: 10, height: 10)
                Text("Recording…").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.destructive)
            }
            HStack(spacing: 14) {
                Button("Cancel") { Task { await coordinator.cancel(); onCancel() } }
                    .buttonStyle(SoftButtonStyle(theme: theme))
                Button {
                    Task { await stopRecording() }
                } label: {
                    Label("Stop & Edit", systemImage: "stop.fill")
                }
                .buttonStyle(PremiumButtonStyle(theme: theme))
            }
        }
    }

    private func startRecording() async {
        errorMessage = nil
        // Screen Recording permission is mandatory.
        let screen = await coordinator.permissions.screenRecordingStatus()
        if screen != .granted {
            if await coordinator.permissions.requestScreenRecording() == false {
                errorMessage = "Grant Screen Recording permission in System Settings, then try again."
                coordinator.permissions.openSettings(.screenRecording)
                return
            }
        }
        // Accessibility powers real click capture (falls back gracefully if absent).
        _ = coordinator.permissions.requestAccessibility(prompt: true)
        if captureMic, coordinator.permissions.microphoneStatus() != .granted {
            _ = await coordinator.permissions.requestMicrophone()
        }
        if captureWebcam, coordinator.permissions.cameraStatus() != .granted {
            _ = await coordinator.permissions.requestCamera()
        }

        let options = RecordingOptions(
            source: .fullscreen(displayID: nil),
            microphone: captureMic, microphoneDeviceID: micDeviceID,
            webcam: captureWebcam, cameraDeviceID: cameraDeviceID,
            systemAudio: captureSystemAudio, fps: fps)
        do {
            try await coordinator.start(options: options)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        do {
            let result = try await coordinator.stop()
            onFinished(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
