import SwiftUI
import SmooothCore

struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var showExport = false
    @State private var showSavePreset = false
    @State private var newPresetName = "My Preset"

    private var theme: Theme { Theme(model.mode) }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Body: sidebar (left) + main column (preview / transport / timeline)
            HStack(spacing: 0) {
                SidePanelView(model: model)
                    .frame(width: 448)
                    .background(theme.sidebar)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(theme.sidebarBorder).frame(width: 1)
                    }

                VStack(spacing: 0) {
                    LayerPreview(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                    transport
                    TimelineView(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
            }
        }
        .background(theme.background)
        .environment(\.theme, theme)
        .preferredColorScheme(model.mode == "dark" ? .dark : .light)
        .sheet(isPresented: $showExport) { ExportView(model: model) }
        .sheet(isPresented: $showSavePreset) { savePresetSheet }
    }

    // MARK: - Header (h = 48)

    private var header: some View {
        ZStack {
            // Left cluster: Presets dropdown, Settings gear, undo/redo
            HStack(spacing: 8) {
                presetsMenu
                Button { model.activeSidePanelTab = .settings } label: {
                    Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.mutedForeground)
                .frame(width: 30, height: 30)
                .background(theme.secondary.opacity(0.0))
                .help("Settings")

                Divider().frame(height: 18)

                Button { model.undoManager.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(theme.mutedForeground)
                .frame(width: 28, height: 28)
                .disabled(!model.undoManager.canUndo)
                .opacity(model.undoManager.canUndo ? 1 : 0.4)
                .keyboardShortcut("z", modifiers: .command)

                Button { model.undoManager.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(theme.mutedForeground)
                .frame(width: 28, height: 28)
                .disabled(!model.undoManager.canRedo)
                .opacity(model.undoManager.canRedo ? 1 : 0.4)
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Spacer()
            }
            .padding(.horizontal, 12)

            // Centered title
            Text("Smoooth")
                .font(.system(size: 13, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(theme.foreground)

            // Right: Export
            HStack {
                Spacer()
                Button { showExport = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PremiumButtonStyle(theme: theme))
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.duration <= 0)
                .opacity(model.duration <= 0 ? 0.5 : 1)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 48)
        .background(.regularMaterial)
        .background(theme.card.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var presetsMenu: some View {
        Menu {
            ForEach(Array(model.presets.values).sorted { $0.name < $1.name }) { preset in
                Button { model.applyPreset(preset.id) } label: {
                    if preset.id == model.activePresetID { Label(preset.name, systemImage: "checkmark") }
                    else { Text(preset.name) }
                }
            }
            Divider()
            Button("Save Current as Preset…") { showSavePreset = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 12, weight: .semibold))
                Text(model.presets[model.activePresetID ?? ""]?.name ?? "Presets")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.secondary)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Transport (centered play + frame-step, time readout, add-region buttons)

    private var transport: some View {
        HStack(spacing: 12) {
            // Add-region buttons (left)
            HStack(spacing: 8) {
                addButton("Zoom", systemImage: "plus.magnifyingglass", color: theme.zoom) { model.addZoomRegion() }
                addButton("Trim", systemImage: "scissors", color: theme.cut) { model.addCutRegion() }
                addButton("Speed", systemImage: "forward.fill", color: theme.speed) { model.addSpeedRegion() }
                if let id = model.selectedRegionID {
                    iconButton("trash", tint: theme.destructive) { model.deleteRegion(id) }
                }
            }

            Spacer()

            // Transport (center)
            HStack(spacing: 14) {
                iconButton("backward.frame.fill") { model.seekFrames(-1) }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primaryForeground)
                        .frame(width: 34, height: 34)
                        .background(theme.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                iconButton("forward.frame.fill") { model.seekFrames(1) }

                Text(timeLabel(model.currentTime) + " / " + timeLabel(model.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.mutedForeground)
            }

            Spacer()

            // Aspect ratio (right)
            HStack(spacing: 8) {
                Text("Aspect").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.mutedForeground)
                Picker("", selection: Binding(get: { model.aspectRatio }, set: { model.setAspectRatio($0) })) {
                    ForEach(AspectRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(theme.card)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private func addButton(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(model.selectedRegionID == nil ? theme.foreground : theme.mutedForeground.opacity(0.5))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.selectedRegionID != nil)
        .help("Add \(title) Region")
    }

    private func iconButton(_ systemImage: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? theme.foreground)
                .frame(width: 34, height: 34)
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save preset sheet

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Preset").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.foreground)
            TextField("Name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showSavePreset = false }
                Spacer()
                Button("Save") { model.saveCurrentAsPreset(name: newPresetName); showSavePreset = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
            }
        }
        .padding(20).frame(width: 300)
        .background(theme.card)
        .environment(\.theme, theme)
    }

    private func timeLabel(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00.00" }
        let m = Int(s) / 60
        let rem = s - Double(m * 60)
        return String(format: "%d:%05.2f", m, rem)
    }
}
