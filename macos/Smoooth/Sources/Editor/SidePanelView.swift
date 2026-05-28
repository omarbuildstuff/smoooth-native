import SwiftUI
import SmooothCore

private let easingOptions = ["Smooth", "Balanced", "Dynamic", "Gentle Spring", "Bouncy Spring"]
private let speedOptions: [(String, Double)] = [("Slow", 1.5), ("Mellow", 1.0), ("Quick", 0.7), ("Rapid", 0.4)]
private let gradientDirections = ["to right", "to left", "to bottom", "to top", "to bottom right", "to bottom left", "to top right", "to top left", "circle-in", "circle-out"]

struct SidePanelView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.activeSidePanelTab) {
                ForEach(SidePanelTab.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch model.activeSidePanelTab {
                    case .general: GeneralPanel(model: model)
                    case .camera: CameraPanel(model: model)
                    case .cursor: CursorPanel(model: model)
                    case .audio: AudioPanel(model: model)
                    case .animation: AnimationPanel(model: model)
                    case .settings: SettingsPanel(model: model)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 300)
    }
}

// MARK: - General (frame + background)

private struct GeneralPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        PanelSection(title: "Aspect Ratio") {
            Picker("", selection: Binding(get: { model.aspectRatio }, set: { model.setAspectRatio($0) })) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.menu)
        }
        PanelSection(title: "Frame") {
            LabeledSlider(title: "Padding", value: $model.frameStyles.padding, range: 0...30)
            LabeledSlider(title: "Corner Radius", value: $model.frameStyles.borderRadius, range: 0...100)
            LabeledSlider(title: "Border Width", value: $model.frameStyles.borderWidth, range: 0...20)
            ColorPicker("Border Color", selection: colorBinding(\.borderColor)).font(.caption)
        }
        PanelSection(title: "Shadow") {
            LabeledSlider(title: "Blur", value: $model.frameStyles.shadowBlur, range: 0...100)
            LabeledSlider(title: "Offset X", value: $model.frameStyles.shadowOffsetX, range: -50...50)
            LabeledSlider(title: "Offset Y", value: $model.frameStyles.shadowOffsetY, range: -50...50)
            ColorPicker("Shadow Color", selection: colorBinding(\.shadowColor)).font(.caption)
        }
        PanelSection(title: "Background") {
            Picker("", selection: Binding(get: { model.frameStyles.background.type },
                                          set: { newType in model.updateBackground { $0.type = newType } })) {
                Text("Color").tag(BackgroundType.color)
                Text("Gradient").tag(BackgroundType.gradient)
                Text("Wallpaper").tag(BackgroundType.wallpaper)
                Text("Image").tag(BackgroundType.image)
            }.labelsHidden().pickerStyle(.segmented)

            switch model.frameStyles.background.type {
            case .color:
                ColorPicker("Color", selection: bgColorBinding(\.color, default: "#101820")).font(.caption)
            case .gradient:
                ColorPicker("Start", selection: bgColorBinding(\.gradientStart, default: "#4f46e5")).font(.caption)
                ColorPicker("End", selection: bgColorBinding(\.gradientEnd, default: "#0ea5e9")).font(.caption)
                Picker("Direction", selection: Binding(
                    get: { model.frameStyles.background.gradientDirection ?? "to bottom right" },
                    set: { d in model.updateBackground { $0.gradientDirection = d } })) {
                    ForEach(gradientDirections, id: \.self) { Text($0).tag($0) }
                }.font(.caption)
            case .wallpaper, .image:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 6) {
                    ForEach(EditorDefaults.wallpapers, id: \.self) { name in
                        wallpaperThumb(name)
                    }
                }
            }
        }
    }

    @ViewBuilder private func wallpaperThumb(_ name: String) -> some View {
        Button {
            model.updateBackground {
                $0.type = .wallpaper
                $0.imageUrl = EditorDefaults.wallpaperImageURL(name)
                $0.thumbnailUrl = EditorDefaults.wallpaperImageURL(name)
            }
        } label: {
            if let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.frameStyles.background.imageUrl?.contains(name) == true ? Color.accentColor : .clear, lineWidth: 2))
            } else { Color.gray.frame(width: 70, height: 40) }
        }.buttonStyle(.plain)
    }

    private func colorBinding(_ key: WritableKeyPath<FrameStyles, String>) -> Binding<Color> {
        Binding(get: { Color(rgbaString: model.frameStyles[keyPath: key]) },
                set: { model.frameStyles[keyPath: key] = $0.rgbaString() })
    }
    private func bgColorBinding(_ key: WritableKeyPath<Background, String?>, default def: String) -> Binding<Color> {
        Binding(get: { Color(rgbaString: model.frameStyles.background[keyPath: key] ?? def) },
                set: { c in model.updateBackground { $0[keyPath: key] = c.rgbaString() } })
    }
}

// MARK: - Camera

private struct CameraPanel: View {
    @Bindable var model: EditorModel
    private let positions: [[WebcamPos?]] = [
        [.topLeft, .topCenter, .topRight],
        [.leftCenter, nil, .rightCenter],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    var body: some View {
        PanelSection(title: "Camera") {
            Toggle("Show webcam", isOn: Binding(get: { model.isWebcamVisible }, set: { model.setWebcamVisibility($0) })).font(.caption)
            Picker("Shape", selection: $model.webcamStyles.shape) {
                Text("Circle").tag(WebcamShape.circle); Text("Square").tag(WebcamShape.square); Text("Rectangle").tag(WebcamShape.rectangle)
            }.font(.caption)
            LabeledSlider(title: "Size", value: $model.webcamStyles.size, range: 10...50)
            LabeledSlider(title: "Corner Radius", value: $model.webcamStyles.borderRadius, range: 0...50)
            Toggle("Flip horizontally", isOn: $model.webcamStyles.isFlipped).font(.caption)
            Toggle("Scale on zoom", isOn: $model.webcamStyles.scaleOnZoom).font(.caption)
            Toggle("Smart position", isOn: $model.webcamStyles.smartPosition).font(.caption)
        }
        PanelSection(title: "Position") {
            ForEach(0..<3) { row in
                HStack {
                    ForEach(0..<3) { col in
                        if let pos = positions[row][col] {
                            Button { model.setWebcamPosition(pos) } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(model.webcamPosition == pos ? Color.accentColor : Color.gray.opacity(0.3))
                                    .frame(height: 26)
                            }.buttonStyle(.plain)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Color.clear).frame(height: 26)
                        }
                    }
                }
            }
        }
        PanelSection(title: "Shadow") {
            LabeledSlider(title: "Blur", value: $model.webcamStyles.shadowBlur, range: 0...80)
            LabeledSlider(title: "Offset Y", value: $model.webcamStyles.shadowOffsetY, range: -40...40)
        }
    }
}

// MARK: - Cursor

private struct CursorPanel: View {
    @Bindable var model: EditorModel
    var body: some View {
        PanelSection(title: "Cursor") {
            Toggle("Show cursor", isOn: $model.cursorStyles.showCursor).font(.caption)
            LabeledSlider(title: "Shadow Blur", value: $model.cursorStyles.shadowBlur, range: 0...20)
        }
        PanelSection(title: "Click Ripple") {
            Toggle("Enabled", isOn: $model.cursorStyles.clickRippleEffect).font(.caption)
            LabeledSlider(title: "Size", value: $model.cursorStyles.clickRippleSize, range: 10...80)
            LabeledSlider(title: "Duration", value: $model.cursorStyles.clickRippleDuration, range: 0.1...2.0, step: 0.05, decimals: 2)
        }
        PanelSection(title: "Click Scale") {
            Toggle("Enabled", isOn: $model.cursorStyles.clickScaleEffect).font(.caption)
            LabeledSlider(title: "Amount", value: $model.cursorStyles.clickScaleAmount, range: 0.5...1.5, step: 0.05, decimals: 2)
            LabeledSlider(title: "Duration", value: $model.cursorStyles.clickScaleDuration, range: 0.1...1.0, step: 0.05, decimals: 2)
        }
    }
}

// MARK: - Audio

private struct AudioPanel: View {
    @Bindable var model: EditorModel
    var body: some View {
        PanelSection(title: "Audio") {
            Toggle("Mute", isOn: $model.isMuted).font(.caption)
            LabeledSlider(title: "Volume", value: $model.volume, range: 0...1, step: 0.01, decimals: 2)
            if !model.hasAudioTrack {
                Text("No audio track in this recording.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Animation (zoom/speed regions)

private struct AnimationPanel: View {
    @Bindable var model: EditorModel
    var body: some View {
        PanelSection(title: "Auto Zoom") {
            Button("Regenerate from clicks") { _ = model.generateZoomRegionsFromClicks() }.font(.caption)
        }
        if let id = model.selectedRegionID, let zoom = model.zoomRegions[id] {
            PanelSection(title: "Selected Zoom") {
                LabeledSlider(title: "Zoom Level", value: Binding(get: { zoom.zoomLevel },
                    set: { v in model.updateZoomRegion(id) { $0.zoomLevel = v } }), range: 1...3, step: 0.1, decimals: 1)
                Picker("Easing", selection: Binding(get: { zoom.easing },
                    set: { e in model.updateZoomRegion(id) { $0.easing = e } })) {
                    ForEach(easingOptions, id: \.self) { Text($0).tag($0) }
                }.font(.caption)
                Picker("Speed", selection: Binding(get: { zoom.transitionDuration },
                    set: { d in model.updateZoomRegion(id) { $0.transitionDuration = d } })) {
                    ForEach(speedOptions, id: \.1) { Text($0.0).tag($0.1) }
                }.font(.caption)
                Picker("Mode", selection: Binding(get: { zoom.mode },
                    set: { m in model.updateZoomRegion(id) { $0.mode = m } })) {
                    Text("Auto").tag(ZoomMode.auto); Text("Fixed").tag(ZoomMode.fixed)
                }.font(.caption)
                Button("Apply to all zooms") {
                    model.applyAnimationToAll(transitionDuration: zoom.transitionDuration, easing: zoom.easing, zoomLevel: zoom.zoomLevel)
                }.font(.caption)
                Button("Delete", role: .destructive) { model.deleteRegion(id) }.font(.caption)
            }
        } else if let id = model.selectedRegionID, let speed = model.speedRegions[id] {
            PanelSection(title: "Selected Speed") {
                LabeledSlider(title: "Speed", value: Binding(get: { speed.speed },
                    set: { v in model.updateSpeedRegion(id) { $0.speed = v } }), range: 0.25...4, step: 0.25, decimals: 2)
                Button("Apply to all speeds") { model.applySpeedToAll(speed.speed) }.font(.caption)
                Button("Delete", role: .destructive) { model.deleteRegion(id) }.font(.caption)
            }
        } else {
            Text("Select a region on the timeline to edit it.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings

private struct SettingsPanel: View {
    @Bindable var model: EditorModel
    var body: some View {
        PanelSection(title: "Appearance") {
            Picker("Theme", selection: Binding(get: { model.mode }, set: { model.mode = $0; SettingsStore.shared.mode = $0 })) {
                Text("Dark").tag("dark"); Text("Light").tag("light")
            }.font(.caption)
        }
        PanelSection(title: "About") {
            Text("Smoooth • Core v\(SmooothCore.version)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
