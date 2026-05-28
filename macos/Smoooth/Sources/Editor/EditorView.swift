import SwiftUI
import SmooothCore

struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var showExport = false
    @State private var showSavePreset = false
    @State private var newPresetName = "My Preset"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                PreviewView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                Divider()
                SidePanelView(model: model)
            }
            Divider()
            transport
            TimelineView(model: model)
        }
        .preferredColorScheme(model.mode == "dark" ? .dark : .light)
        .sheet(isPresented: $showExport) { ExportView(model: model) }
        .sheet(isPresented: $showSavePreset) {
            VStack(spacing: 16) {
                Text("Save Preset").font(.headline)
                TextField("Name", text: $newPresetName)
                HStack {
                    Button("Cancel") { showSavePreset = false }
                    Spacer()
                    Button("Save") { model.saveCurrentAsPreset(name: newPresetName); showSavePreset = false }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 280)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Array(model.presets.values).sorted { $0.name < $1.name }) { preset in
                    Button(preset.name) { model.applyPreset(preset.id) }
                }
                Divider()
                Button("Save Current as Preset…") { showSavePreset = true }
            } label: {
                Label(model.presets[model.activePresetID ?? ""]?.name ?? "Preset", systemImage: "square.stack.3d.up")
            }.frame(width: 180)

            Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.undoManager.canUndo)
            Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.undoManager.canRedo)

            Spacer()
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("e", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { model.seekFrames(-1) } label: { Image(systemName: "backward.frame") }
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                .keyboardShortcut(.space, modifiers: [])
            Button { model.seekFrames(1) } label: { Image(systemName: "forward.frame") }

            Text(timeLabel(model.currentTime) + " / " + timeLabel(model.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            Spacer()
            Button { model.addZoomRegion() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
            Button { model.addCutRegion() } label: { Label("Cut", systemImage: "scissors") }
            Button { model.addSpeedRegion() } label: { Label("Speed", systemImage: "speedometer") }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .buttonStyle(.bordered)
    }

    private func timeLabel(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00.00" }
        let m = Int(s) / 60
        let rem = s - Double(m * 60)
        return String(format: "%d:%05.2f", m, rem)
    }
}
