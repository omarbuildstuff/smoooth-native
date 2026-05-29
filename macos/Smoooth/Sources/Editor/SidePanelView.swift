import SwiftUI
import SmooothCore

private let easingOptions = ["Smooth", "Balanced", "Dynamic", "Gentle Spring", "Bouncy Spring"]
private let speedOptions: [(String, Double)] = [("Slow", 1.5), ("Mellow", 1.0), ("Quick", 0.7), ("Rapid", 0.4)]
private let gradientDirections = ["to right", "to left", "to bottom", "to top", "to bottom right", "to bottom left", "to top right", "to top left", "circle-in", "circle-out"]

private struct TabInfo {
    let tab: SidePanelTab
    let title: String
    let icon: String
}

private let sidePanelTabs: [TabInfo] = [
    .init(tab: .general, title: "General", icon: "rectangle.on.rectangle"),
    .init(tab: .camera, title: "Camera", icon: "camera"),
    .init(tab: .cursor, title: "Cursor", icon: "cursorarrow"),
    .init(tab: .audio, title: "Audio", icon: "mic"),
    .init(tab: .animation, title: "Animation", icon: "wand.and.stars"),
    .init(tab: .settings, title: "Settings", icon: "gearshape"),
]

struct SidePanelView: View {
    @Bindable var model: EditorModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                        .fill(theme.primary.opacity(0.12))
                    Image(systemName: headerIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.sidebarForeground)
                    Text(headerSubtitle).font(.system(size: 11)).foregroundStyle(theme.mutedForeground)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.sidebarBorder).frame(height: 1) }

            // Tab bar
            tabBar
                .padding(.horizontal, 14)
                .padding(.top, 12)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.activeSidePanelTab {
                    case .general: GeneralPanel(model: model)
                    case .camera: CameraPanel(model: model)
                    case .cursor: CursorPanel(model: model)
                    case .audio: AudioPanel(model: model)
                    case .animation: AnimationPanel(model: model)
                    case .settings: SettingsPanel(model: model)
                    }
                }
                .padding(18)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(sidePanelTabs, id: \.tab) { info in
                let isActive = model.activeSidePanelTab == info.tab
                let disabled = isDisabled(info.tab)
                Button {
                    model.activeSidePanelTab = info.tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: info.icon).font(.system(size: 14, weight: .medium))
                        Text(info.title).font(.system(size: 9, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(isActive ? theme.primary : theme.mutedForeground)
                    .background(isActive ? theme.accent : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
            }
        }
        .padding(4)
        .background(theme.muted)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLg, style: .continuous))
    }

    private func isDisabled(_ tab: SidePanelTab) -> Bool {
        switch tab {
        case .camera: return model.webcamVideoURL == nil
        case .audio: return !model.hasAudioTrack
        default: return false
        }
    }

    private var headerIcon: String { sidePanelTabs.first { $0.tab == model.activeSidePanelTab }?.icon ?? "rectangle.on.rectangle" }
    private var headerTitle: String {
        switch model.activeSidePanelTab {
        case .general: return "General Settings"
        case .camera: return "Camera"
        case .cursor: return "Cursor"
        case .audio: return "Audio"
        case .animation: return "Animation"
        case .settings: return "Settings"
        }
    }
    private var headerSubtitle: String {
        switch model.activeSidePanelTab {
        case .general: return "Customize your video's appearance"
        case .camera: return "Webcam overlay & position"
        case .cursor: return "Cursor & click effects"
        case .audio: return "Volume & mute"
        case .animation: return "Zoom & speed regions"
        case .settings: return "App preferences"
        }
    }
}

// MARK: - General (frame + background)

private struct GeneralPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.theme) private var theme

    var body: some View {
        PanelSection(title: "Aspect Ratio", icon: "aspectratio") {
            Picker("", selection: Binding(get: { model.aspectRatio }, set: { model.setAspectRatio($0) })) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.menu)
        }
        PanelSection(title: "Frame", icon: "square.dashed") {
            LabeledSlider(title: "Padding", value: $model.frameStyles.padding, range: 0...30)
            LabeledSlider(title: "Corner Radius", value: $model.frameStyles.borderRadius, range: 0...100)
            LabeledSlider(title: "Border Width", value: $model.frameStyles.borderWidth, range: 0...20)
            PanelRow(title: "Border Color") {
                ColorPicker("", selection: colorBinding(\.borderColor)).labelsHidden()
            }
        }
        PanelSection(title: "Shadow", icon: "shadow") {
            LabeledSlider(title: "Blur", value: $model.frameStyles.shadowBlur, range: 0...100)
            LabeledSlider(title: "Offset X", value: $model.frameStyles.shadowOffsetX, range: -50...50)
            LabeledSlider(title: "Offset Y", value: $model.frameStyles.shadowOffsetY, range: -50...50)
            PanelRow(title: "Shadow Color") {
                ColorPicker("", selection: colorBinding(\.shadowColor)).labelsHidden()
            }
        }
        PanelSection(title: "Background", icon: "photo") {
            Picker("", selection: Binding(get: { model.frameStyles.background.type },
                                          set: { newType in model.updateBackground { $0.type = newType } })) {
                Text("Color").tag(BackgroundType.color)
                Text("Gradient").tag(BackgroundType.gradient)
                Text("Wallpaper").tag(BackgroundType.wallpaper)
                Text("Image").tag(BackgroundType.image)
            }.labelsHidden().pickerStyle(.segmented)

            switch model.frameStyles.background.type {
            case .color:
                PanelRow(title: "Color") {
                    ColorPicker("", selection: bgColorBinding(\.color, default: "#101820")).labelsHidden()
                }
            case .gradient:
                PanelRow(title: "Start") {
                    ColorPicker("", selection: bgColorBinding(\.gradientStart, default: "#4f46e5")).labelsHidden()
                }
                PanelRow(title: "End") {
                    ColorPicker("", selection: bgColorBinding(\.gradientEnd, default: "#0ea5e9")).labelsHidden()
                }
                PanelRow(title: "Direction") {
                    Picker("", selection: Binding(
                        get: { model.frameStyles.background.gradientDirection ?? "to bottom right" },
                        set: { d in model.updateBackground { $0.gradientDirection = d } })) {
                        ForEach(gradientDirections, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 130)
                }
            case .wallpaper, .image:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(EditorDefaults.wallpapers, id: \.self) { name in
                        wallpaperThumb(name)
                    }
                }
            }
        }
    }

    @ViewBuilder private func wallpaperThumb(_ name: String) -> some View {
        let selected = model.frameStyles.background.imageUrl?.contains(name) == true
        Button {
            model.updateBackground {
                $0.type = .wallpaper
                $0.imageUrl = EditorDefaults.wallpaperImageURL(name)
                $0.thumbnailUrl = EditorDefaults.wallpaperImageURL(name)
            }
        } label: {
            ZStack {
                if let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    theme.muted
                }
            }
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .strokeBorder(selected ? theme.primary : theme.border, lineWidth: selected ? 2 : 1)
            )
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
    @Environment(\.theme) private var theme
    private let positions: [[WebcamPos?]] = [
        [.topLeft, .topCenter, .topRight],
        [.leftCenter, nil, .rightCenter],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    var body: some View {
        PanelSection(title: "Camera", icon: "camera") {
            PanelToggle(title: "Show webcam", isOn: Binding(get: { model.isWebcamVisible }, set: { model.setWebcamVisibility($0) }))
            PanelRow(title: "Shape") {
                Picker("", selection: $model.webcamStyles.shape) {
                    Text("Circle").tag(WebcamShape.circle); Text("Square").tag(WebcamShape.square); Text("Rectangle").tag(WebcamShape.rectangle)
                }.labelsHidden().frame(width: 130)
            }
            LabeledSlider(title: "Size", value: $model.webcamStyles.size, range: 10...50)
            LabeledSlider(title: "Corner Radius", value: $model.webcamStyles.borderRadius, range: 0...50)
            PanelToggle(title: "Flip horizontally", isOn: $model.webcamStyles.isFlipped)
            PanelToggle(title: "Scale on zoom", isOn: $model.webcamStyles.scaleOnZoom)
            PanelToggle(title: "Smart position", isOn: $model.webcamStyles.smartPosition)
        }
        PanelSection(title: "Position", icon: "square.grid.3x3") {
            VStack(spacing: 6) {
                ForEach(0..<3) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3) { col in
                            if let pos = positions[row][col] {
                                let active = model.webcamPosition == pos
                                Button { model.setWebcamPosition(pos) } label: {
                                    RoundedRectangle(cornerRadius: theme.radiusSm, style: .continuous)
                                        .fill(active ? theme.primary : theme.muted)
                                        .frame(height: 28)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: theme.radiusSm, style: .continuous)
                                                .strokeBorder(active ? theme.primary : theme.border, lineWidth: 1)
                                        )
                                }.buttonStyle(.plain)
                            } else {
                                Color.clear.frame(height: 28)
                            }
                        }
                    }
                }
            }
        }
        PanelSection(title: "Shadow", icon: "shadow") {
            LabeledSlider(title: "Blur", value: $model.webcamStyles.shadowBlur, range: 0...80)
            LabeledSlider(title: "Offset Y", value: $model.webcamStyles.shadowOffsetY, range: -40...40)
        }
    }
}

// MARK: - Cursor

private struct CursorPanel: View {
    @Bindable var model: EditorModel
    var body: some View {
        PanelSection(title: "Cursor", icon: "cursorarrow") {
            PanelToggle(title: "Show cursor", isOn: $model.cursorStyles.showCursor)
            PanelRow(title: "Theme") {
                Picker("", selection: $model.cursorStyles.theme) {
                    ForEach(CursorTheme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            if model.cursorStyles.theme != .system {
                LabeledSlider(title: "Cursor Size", value: $model.cursorStyles.size, range: 14...64)
            }
            LabeledSlider(title: "Shadow Blur", value: $model.cursorStyles.shadowBlur, range: 0...20)
        }
        PanelSection(title: "Click Ripple", icon: "circle.circle") {
            PanelToggle(title: "Enabled", isOn: $model.cursorStyles.clickRippleEffect)
            LabeledSlider(title: "Size", value: $model.cursorStyles.clickRippleSize, range: 10...80)
            LabeledSlider(title: "Duration", value: $model.cursorStyles.clickRippleDuration, range: 0.1...2.0, step: 0.05, decimals: 2)
        }
        PanelSection(title: "Click Scale", icon: "arrow.up.left.and.arrow.down.right") {
            PanelToggle(title: "Enabled", isOn: $model.cursorStyles.clickScaleEffect)
            LabeledSlider(title: "Amount", value: $model.cursorStyles.clickScaleAmount, range: 0.5...1.5, step: 0.05, decimals: 2)
            LabeledSlider(title: "Duration", value: $model.cursorStyles.clickScaleDuration, range: 0.1...1.0, step: 0.05, decimals: 2)
        }
    }
}

// MARK: - Audio

private struct AudioPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.theme) private var theme
    var body: some View {
        PanelSection(title: "Audio", icon: "speaker.wave.2") {
            PanelToggle(title: "Mute", isOn: $model.isMuted)
            LabeledSlider(title: "Volume", value: $model.volume, range: 0...1, step: 0.01, decimals: 2)
            if !model.hasAudioTrack {
                Text("No audio track in this recording.")
                    .font(.system(size: 11)).foregroundStyle(theme.mutedForeground)
            }
        }
    }
}

// MARK: - Animation (zoom/speed regions)

private struct AnimationPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.theme) private var theme
    var body: some View {
        PanelSection(title: "Auto Zoom", icon: "sparkles") {
            Button("Regenerate from clicks") { _ = model.generateZoomRegionsFromClicks() }
                .buttonStyle(SoftButtonStyle(theme: theme, prominent: true, height: 30))
        }
        if let id = model.selectedRegionID, let zoom = model.zoomRegions[id] {
            PanelSection(title: "Selected Zoom", icon: "plus.magnifyingglass") {
                LabeledSlider(title: "Zoom Level", value: Binding(get: { zoom.zoomLevel },
                    set: { v in model.updateZoomRegion(id) { $0.zoomLevel = v } }), range: 1...3, step: 0.1, decimals: 1)
                PanelRow(title: "Easing") {
                    Picker("", selection: Binding(get: { zoom.easing },
                        set: { e in model.updateZoomRegion(id) { $0.easing = e } })) {
                        ForEach(easingOptions, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
                PanelRow(title: "Speed") {
                    Picker("", selection: Binding(get: { zoom.transitionDuration },
                        set: { d in model.updateZoomRegion(id) { $0.transitionDuration = d } })) {
                        ForEach(speedOptions, id: \.1) { Text($0.0).tag($0.1) }
                    }.labelsHidden().frame(width: 110)
                }
                PanelRow(title: "Mode") {
                    Picker("", selection: Binding(get: { zoom.mode },
                        set: { m in model.updateZoomRegion(id) { $0.mode = m } })) {
                        Text("Auto").tag(ZoomMode.auto); Text("Fixed").tag(ZoomMode.fixed)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                }
                Button("Apply to all zooms") {
                    model.applyAnimationToAll(transitionDuration: zoom.transitionDuration, easing: zoom.easing, zoomLevel: zoom.zoomLevel)
                }.buttonStyle(SoftButtonStyle(theme: theme, height: 30))
                Button("Delete", role: .destructive) { model.deleteRegion(id) }
                    .buttonStyle(SoftButtonStyle(theme: theme, height: 30))
                    .tint(theme.destructive)
            }
        } else if let id = model.selectedRegionID, let speed = model.speedRegions[id] {
            PanelSection(title: "Selected Speed", icon: "forward.fill") {
                LabeledSlider(title: "Speed", value: Binding(get: { speed.speed },
                    set: { v in model.updateSpeedRegion(id) { $0.speed = v } }), range: 0.25...4, step: 0.25, decimals: 2)
                Button("Apply to all speeds") { model.applySpeedToAll(speed.speed) }
                    .buttonStyle(SoftButtonStyle(theme: theme, height: 30))
                Button("Delete", role: .destructive) { model.deleteRegion(id) }
                    .buttonStyle(SoftButtonStyle(theme: theme, height: 30))
            }
        } else {
            HStack {
                Image(systemName: "hand.tap").foregroundStyle(theme.mutedForeground)
                Text("Select a region on the timeline to edit it.")
                    .font(.system(size: 12)).foregroundStyle(theme.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(theme)
        }
    }
}

// MARK: - Settings

private struct SettingsPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.theme) private var theme
    var body: some View {
        PanelSection(title: "Appearance", icon: "paintpalette") {
            PanelRow(title: "Theme") {
                Picker("", selection: Binding(get: { model.mode }, set: { model.mode = $0; SettingsStore.shared.mode = $0 })) {
                    Text("Dark").tag("dark"); Text("Light").tag("light")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
            }
        }
        PanelSection(title: "About", icon: "info.circle") {
            Text("Smoooth • Core v\(SmooothCore.version)")
                .font(.system(size: 11)).foregroundStyle(theme.mutedForeground)
        }
    }
}
