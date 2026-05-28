# Smoooth — Native macOS (Swift)

A native rewrite of the Electron/React Smoooth app: a cinematic screen recorder with
automatic mouse-driven pan/zoom and a styling editor. **macOS 26+, Apple Silicon.**

This replaces Electron + FFmpeg + Python/node addons with native Apple frameworks:

| Concern | Implementation |
|---|---|
| Screen capture | **ScreenCaptureKit** (`SCStream`) → **AVAssetWriter** (VideoToolbox H.264) |
| System audio / mic | `SCStreamConfiguration.capturesAudio` / `captureMicrophone` |
| Webcam | **AVCaptureSession** |
| Mouse + clicks | **CGEventTap** (+ NSEvent fallback), `NSCursor` snapshot |
| Compositor | **Core Graphics** (`SceneRenderer`) — port of the Canvas2D `drawScene` |
| Live preview | **AVPlayer** + `AVPlayerItemVideoOutput` → SceneRenderer |
| Export | **AVAssetImageGenerator** (exact seeks) → SceneRenderer → AVAssetWriter; GIF via **ImageIO** |
| UI / state | **SwiftUI** + `@Observable` + `UndoManager` |
| Persistence | UserDefaults + JSON (presets) in Application Support |

## Layout

```
macos/
├─ SmooothCore/      Swift package: framework-free logic + compositor + export, fully unit-tested
│   └─ Sources/SmooothCore/  Models, Defaults, Easing, ZoomTransform, TimeRemap, AutoZoom,
│                            Geometry, Color, SceneRenderer, Export/{FrameSource,VideoExporter,…}
├─ Smoooth/          The app (XcodeGen-generated .xcodeproj)
│   └─ Sources/{Capture, Editor, …}, Resources/wallpapers, Supporting/{Info.plist, entitlements}
└─ scripts/          dump-reference-vectors.mjs (parity vectors)
```

`SmooothCore` carries all deterministic logic and is parity-locked against the original
JavaScript via golden vectors (`scripts/dump-reference-vectors.mjs` → `Tests/.../Fixtures/vectors.json`).

## Build & run

Prereqs: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# Core library + tests (headless, no GUI/permissions needed)
cd macos/SmooothCore && swift test            # 58 tests

# App
cd macos/Smoooth
xcodegen generate                              # regenerates Smoooth.xcodeproj (gitignored)
open Smoooth.xcodeproj                          # then Run, or:
xcodebuild -project Smoooth.xcodeproj -scheme Smoooth -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

On first recording macOS will prompt for **Screen Recording** and **Accessibility** (clicks),
plus Camera/Microphone if enabled. Grant them in System Settings → Privacy & Security.

## Feature parity

Record (full screen; area/window engine-ready), webcam overlay, system audio + mic, real click
capture; editor with aspect ratios, backgrounds (color/gradient/wallpaper/image), padding/radius/
shadow/border, cinematic auto + manual zoom (5 easings, speeds, EMA pan), click ripple, cursor
effects, webcam shape/smart-position/scale-on-zoom/flip, timeline (zoom/cut/speed regions),
presets, undo/redo, audio volume/mute; export MP4 (H.264) + GIF at 720p/1080p/2K with cut/speed-
aware duration.

## Known follow-ups

- **Window / area capture UI**: the engine supports `.window`/`.area`; the picker + drag-select
  overlay windows are not yet built (the UI offers full-screen). 
- **Audio for speed regions**: cut-only audio muxes via passthrough (exact); when speed regions are
  present the audio is re-encoded (HighestQuality) to apply time scaling.
- **On-device cursor fidelity**: hotspot scaling + premultiplied byte order are implemented; verify
  pixel-exactness on a real recording once Screen Recording permission is granted.
- **Capture unit tests**: geometry/hotspot/metadata math is pure and untested by XCTest (only
  SmooothCore is covered) — good candidates for follow-up tests.

## Code signing & notarization

The app currently builds **unsigned / ad-hoc** for local use. To distribute it, see
[`docs/SIGNING.md`](docs/SIGNING.md) — a single configuration step once you have an Apple
Developer ID.
