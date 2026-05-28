import SwiftUI
import AppKit
import SmooothCore

/// The recorder control panel: choose what to capture, gate on permissions, then
/// drive RecordingCoordinator. On stop, hands the result back to load into the editor.
struct RecorderView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    var onFinished: (RecordingResult) -> Void
    var onCancel: () -> Void

    @State private var captureSystemAudio = false
    @State private var captureMic = false
    @State private var captureWebcam = false
    @State private var micDeviceID: String?
    @State private var cameraDeviceID: String?
    @State private var fps = 60
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("New Recording").font(.title2.bold())

            if coordinator.state == .recording {
                recordingControls
            } else {
                optionsForm
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 420)
        .onAppear { coordinator.enumerateDevices() }
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("System audio", isOn: $captureSystemAudio)
            Toggle("Microphone", isOn: $captureMic)
            if captureMic {
                Picker("Mic", selection: $micDeviceID) {
                    Text("Default").tag(String?.none)
                    ForEach(coordinator.availableDevices.microphones) { Text($0.name).tag(String?.some($0.id)) }
                }
            }
            Toggle("Webcam overlay", isOn: $captureWebcam)
            if captureWebcam {
                Picker("Camera", selection: $cameraDeviceID) {
                    Text("Default").tag(String?.none)
                    ForEach(coordinator.availableDevices.cameras) { Text($0.name).tag(String?.some($0.id)) }
                }
            }
            Picker("Frame rate", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }

            HStack {
                Button("Back") { onCancel() }
                Spacer()
                Button {
                    Task { await startRecording() }
                } label: {
                    Label("Record Full Screen", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.state != .idle)
            }
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 16) {
            Label("Recording…", systemImage: "record.circle.fill")
                .foregroundStyle(.red).font(.title3)
            HStack(spacing: 16) {
                Button("Cancel") { Task { await coordinator.cancel(); onCancel() } }
                Button("Stop & Edit") { Task { await stopRecording() } }
                    .buttonStyle(.borderedProminent)
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
