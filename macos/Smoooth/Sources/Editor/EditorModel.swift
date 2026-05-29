import Foundation
import CoreGraphics
import Observation
import QuartzCore
import SmooothCore

enum SidePanelTab: String, CaseIterable, Sendable {
    case general, camera, cursor, audio, animation, settings
}

/// Central editor state, mirroring the original Zustand `editorStore` slices.
/// Drives the preview/timeline/side panels and feeds the exporter.
@MainActor
@Observable
final class EditorModel {
    // Project
    var videoURL: URL?
    var webcamVideoURL: URL?
    /// Seconds to delay the webcam relative to the screen/mic timeline. The camera
    /// warms up later than screen capture, so its file starts this far in; preview
    /// and export shift the webcam by this to keep the face synced to the voice.
    /// Auto-detected on load (capture metadata or duration gap), manually tunable.
    var webcamOffset: Double = 0
    /// Seconds to delay the audio relative to the screen video (+ = later, − =
    /// earlier). Manual only; 0 by default since capture aligns mic to screen.
    var audioOffset: Double = 0
    var metadataURL: URL?
    var videoDimensions = SizeD(width: 1920, height: 1080)
    var recordingGeometry: RectD?
    var screenSize: SizeD?
    var duration: Double = 0
    var sourceFPS: Double = 30
    var metadata: [MetaDataItem] = []
    var cursorBitmaps: [String: CursorBitmap] = [:]
    var hasAudioTrack = false

    /// Bundled image cursor (Bayzo), loaded once. Hotspot = the arrow tip (the
    /// right-pointing vertex of the edited artwork).
    @ObservationIgnored lazy var customCursor: CursorBitmap? = Self.loadBayzoCursor()
    private static func loadBayzoCursor() -> CursorBitmap? {
        guard let url = Bundle.main.url(forResource: "BayzoCursor", withExtension: "png"),
              let cg = ImageLoader.load(url) else { return nil }
        let w = Double(cg.width), h = Double(cg.height)
        // Hotspot = the pointer's tip, the top-left apex of the arrow.
        return CursorBitmap(image: cg, width: w, height: h, xhot: w * 0.28, yhot: h * 0.11)
    }

    // Playback
    var isPlaying = false
    var currentTime: Double = 0

    // Frame / background
    var frameStyles: FrameStyles = EditorDefaults.defaultFrameStyles()
    var aspectRatio: AspectRatio = .r16x9
    private(set) var backgroundImage: CGImage?

    // Timeline
    var zoomRegions: [String: ZoomRegion] = [:]
    var cutRegions: [String: CutRegion] = [:]
    var speedRegions: [String: SpeedRegion] = [:]
    var selectedRegionID: String?

    // Presets
    var presets: [String: Preset] = [:]
    var activePresetID: String?

    // Webcam
    var isWebcamVisible = false
    var webcamPosition: WebcamPos = Defaults.Camera.positionDefault
    var webcamStyles: WebcamStyles = EditorDefaults.defaultWebcamStyles()

    // UI
    var mode: String = SettingsStore.shared.mode
    var cursorStyles: CursorStyles = EditorDefaults.defaultCursorStyles()
    var activeSidePanelTab: SidePanelTab = .general

    // Audio
    var volume: Double = Defaults.Audio.volume.defaultValue
    var isMuted = false

    @ObservationIgnored let undoManager = UndoManager()

    init() {
        refreshBackgroundImage()
    }

    // MARK: - Derived

    var sceneModel: SceneModel {
        SceneModel(frameStyles: frameStyles, videoDimensions: videoDimensions,
                   recordingGeometry: recordingGeometry.map { SizeD(width: $0.width, height: $0.height) },
                   zoomRegions: zoomRegions, metadata: metadata, cursorStyles: cursorStyles,
                   isWebcamVisible: isWebcamVisible, webcamPosition: webcamPosition, webcamStyles: webcamStyles)
    }

    /// Final exported duration honoring cut + speed regions.
    var exportDuration: Double {
        TimeRemap.exportDuration(duration, cutRegions: cutRegions, speedRegions: speedRegions)
    }

    func refreshBackgroundImage() {
        switch frameStyles.background.type {
        case .image, .wallpaper:
            backgroundImage = ImageLoader.cgImage(forBackgroundURL: frameStyles.background.imageUrl)
        case .color, .gradient:
            backgroundImage = nil
        }
    }

    // MARK: - Project loading

    func loadProject(videoURL: URL, metadataURL: URL, webcamVideoURL: URL?) async {
        self.videoURL = videoURL
        self.metadataURL = metadataURL
        self.webcamVideoURL = webcamVideoURL

        if let meta = try? RecordingMetadata.load(metadataURL) {
            metadata = meta.events.sorted { $0.timestamp < $1.timestamp }
            recordingGeometry = meta.recordingGeometry
            cursorBitmaps = meta.cursorBitmaps()
            if let s = meta.screenSize { screenSize = SizeD(width: s.width, height: s.height) }
        }

        let source = FrameSource(url: videoURL)
        if let size = try? await source.videoSize() { videoDimensions = size }
        if recordingGeometry == nil {
            recordingGeometry = RectD(x: 0, y: 0, width: videoDimensions.width, height: videoDimensions.height)
        }
        if let dur = try? await source.duration() { duration = dur }

        await recomputeWebcamOffset()
        audioOffset = 0
        sourceFPS = await source.nominalFrameRate()
        hasAudioTrack = await source.hasAudio()

        initializePresets()
        // A recording with a webcam track should show the overlay by default.
        if webcamVideoURL != nil { isWebcamVisible = true }
        _ = generateZoomRegionsFromClicks()
        currentTime = 0
        refreshBackgroundImage()
        // A freshly loaded project has no undo history (auto-zoom is part of load).
        undoManager.removeAllActions()
    }

    // MARK: - Undo

    struct DocSnapshot {
        var zoomRegions: [String: ZoomRegion]
        var cutRegions: [String: CutRegion]
        var speedRegions: [String: SpeedRegion]
        var selectedRegionID: String?
        var frameStyles: FrameStyles
        var aspectRatio: AspectRatio
        var webcamPosition: WebcamPos
        var webcamStyles: WebcamStyles
        var isWebcamVisible: Bool
        var cursorStyles: CursorStyles
    }

    private func snapshot() -> DocSnapshot {
        DocSnapshot(zoomRegions: zoomRegions, cutRegions: cutRegions, speedRegions: speedRegions,
                    selectedRegionID: selectedRegionID, frameStyles: frameStyles, aspectRatio: aspectRatio,
                    webcamPosition: webcamPosition, webcamStyles: webcamStyles,
                    isWebcamVisible: isWebcamVisible, cursorStyles: cursorStyles)
    }

    private func restore(_ s: DocSnapshot) {
        zoomRegions = s.zoomRegions; cutRegions = s.cutRegions; speedRegions = s.speedRegions
        selectedRegionID = s.selectedRegionID; frameStyles = s.frameStyles; aspectRatio = s.aspectRatio
        webcamPosition = s.webcamPosition; webcamStyles = s.webcamStyles
        isWebcamVisible = s.isWebcamVisible; cursorStyles = s.cursorStyles
        refreshBackgroundImage()
    }

    private func registerUndo(from before: DocSnapshot) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.snapshot()
                model.restore(before)
                model.registerUndo(from: current)
            }
        }
    }

    /// Wraps a user edit so it participates in undo/redo.
    func performEdit(_ label: String = "Edit", _ mutate: () -> Void) {
        let before = snapshot()
        mutate()
        registerUndo(from: before)
        undoManager.setActionName(label)
    }

    // Interactive (drag) edits: one snapshot at gesture start, one undo at end.
    @ObservationIgnored private var interactiveSnapshot: DocSnapshot?

    func beginInteractiveEdit() { if interactiveSnapshot == nil { interactiveSnapshot = snapshot() } }
    func endInteractiveEdit(_ label: String = "Move Region") {
        guard let before = interactiveSnapshot else { return }
        interactiveSnapshot = nil
        registerUndo(from: before)
        undoManager.setActionName(label)
    }
    func setRegionStartLive(_ id: String, _ start: Double) {
        if zoomRegions[id] != nil { zoomRegions[id]!.startTime = start }
        else if cutRegions[id] != nil { cutRegions[id]!.startTime = start }
        else if speedRegions[id] != nil { speedRegions[id]!.startTime = start }
    }

    // MARK: - Frame / background

    func setAspectRatio(_ r: AspectRatio) { performEdit("Aspect Ratio") { aspectRatio = r } }

    func updateFrameStyle(_ mutate: (inout FrameStyles) -> Void) {
        performEdit("Frame Style") { mutate(&frameStyles) }
        ensureActivePresetWritable()
    }

    func updateBackground(_ mutate: (inout Background) -> Void) {
        performEdit("Background") { mutate(&frameStyles.background); refreshBackgroundImage() }
        ensureActivePresetWritable()
    }

    // MARK: - Timeline

    private func recalcZIndices() {
        var all: [(id: String, dur: Double)] = []
        all += zoomRegions.values.map { ($0.id, $0.duration) }
        all += cutRegions.values.map { ($0.id, $0.duration) }
        all += speedRegions.values.map { ($0.id, $0.duration) }
        all.sort { $0.dur < $1.dur }
        let count = all.count
        for (index, item) in all.enumerated() {
            let z = 10 + (count - 1 - index)
            if zoomRegions[item.id] != nil { zoomRegions[item.id]!.zIndex = z }
            else if cutRegions[item.id] != nil { cutRegions[item.id]!.zIndex = z }
            else if speedRegions[item.id] != nil { speedRegions[item.id]!.zIndex = z }
        }
    }

    func addZoomRegion() {
        guard duration > 0 else { return }
        performEdit("Add Zoom") {
            let last = metadata.last { $0.timestamp <= currentTime }
            let id = "zoom-\(Int(Date().timeIntervalSince1970 * 1000))"
            var region = ZoomRegion(id: id, startTime: currentTime, duration: Defaults.Zoom.defaultDuration,
                                    zoomLevel: Defaults.Zoom.defaultLevel, easing: Defaults.Zoom.defaultEasing,
                                    transitionDuration: Defaults.Zoom.defaultTransitionDuration,
                                    targetX: (last != nil && recordingGeometry != nil) ? last!.x / recordingGeometry!.width - 0.5 : 0,
                                    targetY: (last != nil && recordingGeometry != nil) ? last!.y / recordingGeometry!.height - 0.5 : 0,
                                    mode: .auto, zIndex: 0)
            if region.startTime + region.duration > duration {
                region.duration = max(Defaults.Timeline.minimumRegionDuration, duration - region.startTime)
            }
            zoomRegions[id] = region
            selectedRegionID = id
            recalcZIndices()
        }
    }

    func addCutRegion() {
        guard duration > 0 else { return }
        performEdit("Add Cut") {
            let id = "cut-\(Int(Date().timeIntervalSince1970 * 1000))"
            var region = CutRegion(id: id, startTime: currentTime, duration: 2, zIndex: 0)
            if region.startTime + region.duration > duration {
                region.duration = max(Defaults.Timeline.minimumRegionDuration, duration - region.startTime)
            }
            cutRegions[id] = region
            selectedRegionID = id
            recalcZIndices()
        }
    }

    func addSpeedRegion() {
        guard duration > 0 else { return }
        performEdit("Add Speed") {
            let id = "speed-\(Int(Date().timeIntervalSince1970 * 1000))"
            var region = SpeedRegion(id: id, startTime: currentTime, duration: 3, speed: 1.5, zIndex: 0)
            if region.startTime + region.duration > duration {
                region.duration = max(Defaults.Timeline.minimumRegionDuration, duration - region.startTime)
            }
            speedRegions[id] = region
            selectedRegionID = id
            recalcZIndices()
        }
    }

    func updateZoomRegion(_ id: String, _ mutate: (inout ZoomRegion) -> Void) {
        guard var r = zoomRegions[id] else { return }
        let oldDur = r.duration
        performEdit("Edit Zoom") { mutate(&r); zoomRegions[id] = r; if oldDur != r.duration { recalcZIndices() } }
    }
    func updateCutRegion(_ id: String, _ mutate: (inout CutRegion) -> Void) {
        guard var r = cutRegions[id] else { return }
        let oldDur = r.duration
        performEdit("Edit Cut") { mutate(&r); cutRegions[id] = r; if oldDur != r.duration { recalcZIndices() } }
    }
    func updateSpeedRegion(_ id: String, _ mutate: (inout SpeedRegion) -> Void) {
        guard var r = speedRegions[id] else { return }
        let oldDur = r.duration
        performEdit("Edit Speed") { mutate(&r); speedRegions[id] = r; if oldDur != r.duration { recalcZIndices() } }
    }

    func deleteRegion(_ id: String) {
        performEdit("Delete Region") {
            zoomRegions[id] = nil; cutRegions[id] = nil; speedRegions[id] = nil
            if selectedRegionID == id { selectedRegionID = nil }
            recalcZIndices()
        }
    }

    func applyAnimationToAll(transitionDuration: Double, easing: String, zoomLevel: Double) {
        performEdit("Apply Animation to All") {
            for id in zoomRegions.keys {
                zoomRegions[id]!.transitionDuration = transitionDuration
                zoomRegions[id]!.easing = easing
                zoomRegions[id]!.zoomLevel = zoomLevel
            }
        }
    }

    func applySpeedToAll(_ speed: Double) {
        performEdit("Apply Speed to All") {
            for id in speedRegions.keys { speedRegions[id]!.speed = speed }
        }
    }

    @discardableResult
    func generateZoomRegionsFromClicks() -> Int {
        guard let geo = recordingGeometry else { return 0 }
        let regions = AutoZoom.generate(metadata: metadata,
                                        recordingGeometry: SizeD(width: geo.width, height: geo.height),
                                        duration: duration)
        if regions.isEmpty { return 0 }
        performEdit("Auto Zoom") {
            zoomRegions = [:]
            for r in regions { zoomRegions[r.id] = r }
            selectedRegionID = nil
            recalcZIndices()
        }
        return regions.count
    }

    // MARK: - Webcam

    /// Auto-detects the webcam→screen timeline offset (camera warmup). The camera
    /// starts later than screen capture but both stop together, so the webcam file
    /// is shorter by exactly the warmup — i.e. the duration gap IS how far the
    /// webcam sits into the screen/audio timeline. This is far more reliable than a
    /// capture-time wall-clock estimate. Used on load and by the "Auto" sync button.
    func recomputeWebcamOffset() async {
        guard let wurl = webcamVideoURL else { webcamOffset = 0; return }
        if let wDur = try? await FrameSource(url: wurl).duration(), wDur > 0, duration > wDur {
            webcamOffset = duration - wDur
        } else {
            webcamOffset = 0
        }
    }

    func setWebcamVisibility(_ v: Bool) { performEdit("Webcam") { isWebcamVisible = v } }
    func setWebcamPosition(_ p: WebcamPos) { performEdit("Webcam Position") { webcamPosition = p } }
    func updateWebcamStyle(_ mutate: (inout WebcamStyles) -> Void) {
        performEdit("Webcam Style") { mutate(&webcamStyles) }
        ensureActivePresetWritable()
    }

    // MARK: - Cursor / UI

    func updateCursorStyle(_ mutate: (inout CursorStyles) -> Void) { performEdit("Cursor Style") { mutate(&cursorStyles) } }

    func toggleMode() {
        mode = (mode == "dark") ? "light" : "dark"
        SettingsStore.shared.mode = mode
    }

    // MARK: - Audio

    func setVolume(_ v: Double) { volume = min(1, max(0, v)) }
    func toggleMute() { isMuted.toggle() }

    // MARK: - Presets

    func initializePresets() {
        var loaded = SettingsStore.shared.loadPresets()
        loaded[EditorDefaults.defaultPresetID] = EditorDefaults.defaultPreset()
        presets = loaded
        let last = SettingsStore.shared.lastActivePresetID
        let target = (last.flatMap { loaded[$0] != nil ? $0 : nil }) ?? EditorDefaults.defaultPresetID
        applyPreset(target)
    }

    func applyPreset(_ id: String) {
        guard let preset = presets[id] else { return }
        frameStyles = preset.styles
        aspectRatio = preset.aspectRatio
        if let ws = preset.webcamStyles { webcamStyles = ws }
        if let wp = preset.webcamPosition { webcamPosition = wp }
        if let vis = preset.isWebcamVisible { isWebcamVisible = vis }
        activePresetID = id
        SettingsStore.shared.lastActivePresetID = id
        refreshBackgroundImage()
        undoManager.removeAllActions()
    }

    func saveCurrentAsPreset(name: String) {
        let id = "preset-\(Int(Date().timeIntervalSince1970 * 1000))"
        let preset = Preset(id: id, name: name, styles: frameStyles, aspectRatio: aspectRatio,
                            isDefault: false, webcamStyles: webcamStyles, webcamPosition: webcamPosition,
                            isWebcamVisible: isWebcamVisible)
        presets[id] = preset
        activePresetID = id
        persistPresets()
        SettingsStore.shared.lastActivePresetID = id
    }

    func updatePresetName(_ id: String, _ name: String) {
        guard presets[id] != nil else { return }
        presets[id]!.name = name
        persistPresets()
    }

    func deletePreset(_ id: String) {
        guard id != EditorDefaults.defaultPresetID else { return }
        presets[id] = nil
        if activePresetID == id { applyPreset(EditorDefaults.defaultPresetID) }
        persistPresets()
    }

    /// If the active preset is the read-only default, fork edits into a writable copy
    /// (mirrors `_ensureActivePresetIsWritable`).
    private func ensureActivePresetWritable() {
        // Non-destructive in this port: edits live on the working state; presets are
        // only written via explicit save. (Kept as a hook for parity.)
    }

    private func persistPresets() {
        var toSave = presets
        toSave[EditorDefaults.defaultPresetID] = nil // default is synthesized, not persisted
        SettingsStore.shared.savePresets(toSave)
    }

    // MARK: - Playback
    // PreviewView owns the playback clock (AVPlayer); these just toggle intent.

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard duration > 0 else { return }
        if currentTime >= duration { currentTime = 0 }
        isPlaying = true
    }

    func pause() { isPlaying = false }

    func seek(to time: Double) {
        currentTime = min(max(0, time), max(0, duration))
    }

    func seekFrames(_ delta: Int) {
        seek(to: currentTime + Double(delta) / max(1, sourceFPS))
    }
}
