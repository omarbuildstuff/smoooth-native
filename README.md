# Cursorful

Native macOS screen recorder with auto-zoom, custom cursor effects, and screen mockups. Built for Apple Silicon (M2+) with SwiftUI, ScreenCaptureKit, Metal, and AVFoundation — zero external dependencies.

Targets feature parity with [Screen Studio](https://screen.studio) / [Cursorful](https://cursorful.com).

## Status

All 13 phases from the plan are scaffolded. Runs on macOS 14+.

- **Capture**: ScreenCaptureKit → HEVC `.mov` via AVAssetWriter, 60fps hardware-encoded
- **Event sync**: Unified `mach_absolute_time` clock; `CGEventTap` + 120Hz cursor polling; events persisted to `events.jsonl`
- **Effects pipeline**: Custom Metal render graph (`Shaders.metal`) with 4 shaders — zoom/pan, cursor SDF, click ripple, mockup+background+shadow
- **Auto-zoom**: `AutoZoomPlanner` clusters clicks into gestures and emits cinematic zoom keyframes with `easeInOutQuart` timing
- **Timeline**: SwiftUI Canvas ruler + zoom-region chips + scrub playhead; non-destructive edits persisted to `project.json`
- **Editor**: live Metal preview (MTKView), inspector panel with mockup/cursor/zoom knobs
- **Export**: `VTCompressionSession` HEVC/H.264 with 7 presets (4K 60 → 720p 30 → 1080×1920 portrait)
- **Tests**: `TimingFunctionTests`, `AutoZoomPlannerTests`, `EventClockTests` — 11 tests, all passing

## Quick start

```bash
cd /Users/umar/claude/Cursorful
xcodegen generate
open Cursorful.xcodeproj
# ⌘R to run
```

Or from command line:

```bash
xcodebuild -scheme Cursorful -destination 'platform=macOS,arch=arm64' build
open /Applications/Cursorful.app    # symlinked to DerivedData build
```

On first launch, grant:
1. **Screen Recording** — System Settings → Privacy & Security → Screen Recording
2. **Accessibility** — System Settings → Privacy & Security → Accessibility (needed for `CGEventTap` click capture)

Then relaunch. Recordings land in `~/Movies/Cursorful/Recordings/<uuid>.cursorful/`.

## Shortcuts

| Shortcut | Action |
|---|---|
| `⇧⌘2` | Start recording (fullscreen) |
| `⇧⌘4` | Start recording (frontmost window) |
| `⇧⌘.` | Stop recording |

Editor opens automatically when a recording finishes.

## Project layout

```
Cursorful/
├── App/             @main entry, AppDelegate, dependency container
├── Core/
│   ├── Capture/     ScreenCapturer (SCStream), CursorTracker (CGEventTap), EventClock
│   ├── Storage/     ScratchWriter (AVAssetWriter), EventLogWriter (JSONL), bundle layout
│   ├── Effects/     EffectGraph, Metal renderer, TextureCache
│   │   ├── Filters/     Zoom, CursorOverlay, ClickRipple, MockupFrame
│   │   └── Keyframes/   TimingFunction, AutoZoomPlanner
│   ├── Preview/     FrameProvider (AVAssetReader), PreviewRenderer (MTKView)
│   ├── Timeline/    Project, TimelineModel (Codable non-destructive edits)
│   └── Export/      Exporter, VideoEncoder (VTCompressionSession), ExportPreset
├── Features/
│   ├── Onboarding/  MainWindowView, PermissionsWindow
│   ├── Recorder/    Floating capsule (NSPanel)
│   ├── Editor/      EditorView, PreviewPanel, InspectorPanel, TimelinePanel
│   ├── Export/      ExportSheet
│   └── MenuBar/     NSStatusItem
├── Resources/       Shaders.metal (vertex + 4 fragment shaders)
├── UI/              DesignSystem, GlassPanel, PillButton, SF Symbol constants
└── Utils/           Logger (os.Logger), CMTime+, Geometry+, Throttle
```

## Regenerate project

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). To regenerate after adding/moving files:

```bash
xcodegen generate
```

## Running tests

```bash
xcodebuild -project Cursorful.xcodeproj -scheme Cursorful -destination 'platform=macOS,arch=arm64' test
```

## Notes

- **Sandbox is off** (`Cursorful.entitlements`). Personal-use only; re-enable before any distribution.
- **Accessibility permission is bundle-path-sensitive.** The `/Applications/Cursorful.app` symlink keeps the permission stable across rebuilds — if you remove it, you'll need to re-grant Accessibility every time Xcode regenerates DerivedData.
- **HDR displays**: `SCStreamConfiguration.colorSpaceName` forced to sRGB to avoid muted SDR output. Wire up proper HDR handling in a future phase.

## What's implemented vs stubbed

**Fully implemented**: capture pipeline, event sync, auto-zoom, cursor overlay (SDF arrow), click ripple, mockup/background/shadow, timeline with scrubbing, project save/load, export with presets, permissions flow.

**Deferred to later phases per plan**: webcam PiP (Phase 9), motion blur (P10), GIF export (P10), keyboard overlay (P10), transcription (P11), silence auto-trim (P12), iOS device frames (P13), audio capture (P8 — currently capture is video-only to keep the v1 pipeline clean).
