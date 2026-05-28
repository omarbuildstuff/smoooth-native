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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var captureSystemAudio = false
    @State private var captureMic = false
    @State private var captureWebcam = false
    @State private var micDeviceID: String?
    @State private var cameraDeviceID: String?
    @State private var fps = 60
    @State private var errorMessage: String?
    @State private var recStart: Date?
    @State private var pulse = false

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
        VStack(spacing: 20) {
            // Big pulsing record indicator.
            ZStack {
                Circle().strokeBorder(theme.destructive.opacity(0.4), lineWidth: 2)
                    .frame(width: 104, height: 104)
                    .scaleEffect(pulse && !reduceMotion ? 1.18 : 0.92)
                    .opacity(pulse && !reduceMotion ? 0 : 0.9)
                Circle().fill(theme.destructive.opacity(0.14)).frame(width: 84, height: 84)
                Circle().fill(theme.destructive).frame(width: 28, height: 28)
                    .shadow(color: theme.destructive.opacity(0.6), radius: 12)
            }
            .frame(height: 110)

            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsedString(ctx.date))
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(theme.foreground)
            }
            Text("Recording your screen — auto-zoom is tracking your cursor")
                .font(.system(size: 12)).foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                Button("Cancel") { Task { await coordinator.cancel(); onCancel() } }
                    .buttonStyle(SoftButtonStyle(theme: theme, height: 44))
                Button { Task { await stopRecording() } } label: {
                    Label("Stop & Edit", systemImage: "stop.fill").frame(width: 150)
                }
                .buttonStyle(PremiumButtonStyle(theme: theme, height: 44))
            }
            .font(.system(size: 14, weight: .semibold))
            .padding(.top, 4)
        }
        .onAppear { if !reduceMotion { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true } } }
    }

    private func elapsedString(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(recStart ?? now)))
        return String(format: "%02d:%02d", s / 60, s % 60)
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
            recStart = Date()
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
