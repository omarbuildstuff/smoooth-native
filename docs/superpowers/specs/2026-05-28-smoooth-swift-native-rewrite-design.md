# Smoooth — Native Swift (macOS) Rewrite — Design Spec

**Date:** 2026-05-28
**Author:** Umar (with Claude)
**Status:** Approved direction — full feature parity, unsigned/ad-hoc build
**Target:** Apple Silicon (M2), macOS 26 (latest). Xcode 26.2 / Swift 6.2.

---

## 1. Goal

Convert the existing Electron + React/TypeScript app "Smoooth" (screen recorder with
cinematic auto pan/zoom and a styling editor) into a **native macOS app written in Swift**,
optimized for Apple Silicon / latest macOS, with **full feature parity**, then QA-validate it
to production readiness.

Non-goals: Windows/Linux (native build is macOS-only — this is the explicit target). Code
signing + notarization are deferred (build ad-hoc/unsigned for local use; signing wired as a
single documented final step).

## 2. Why native (and why it's the right "optimized for M2" answer)

The current macOS path is a convoluted Electron workaround: the renderer captures the screen
via ScreenCaptureKit through `getDisplayMedia`/`MediaRecorder` into a WebM, FFmpeg muxes it to
MP4, mic/webcam come through `avfoundation`, mouse tracking uses a native node addon, and
export streams raw RGBA frames from an offscreen Chromium canvas into FFmpeg.

Native Apple frameworks collapse all of this and run hardware-accelerated on M2:

| Concern | Electron (now) | Native Swift (target) |
|---|---|---|
| Screen capture | ScreenCaptureKit via Chromium → WebM → FFmpeg mux | **ScreenCaptureKit** `SCStream` → **AVAssetWriter** (one path) |
| System audio | electron-audio-loopback / CoreAudio tap | **SCStream** `capturesAudio` |
| Microphone | FFmpeg avfoundation | **SCStream** `captureMicrophone` (macOS 15+) / AVCaptureSession |
| Webcam | FFmpeg avfoundation | **AVCaptureSession** |
| Mouse + clicks | native node addon + dwell synthesis | **CGEventTap** (real clicks) + NSCursor image/hotspot |
| Video encode | FFmpeg libx264 (CPU) | **VideoToolbox** H.264/HEVC (hardware) |
| Compositor | Canvas2D in offscreen Chromium | **Core Graphics / Metal** |
| Export GIF | FFmpeg palettegen | **ImageIO** `CGImageDestination` |
| UI | React + Tailwind | **SwiftUI** |
| State | Zustand + immer + zundo | `@Observable` model + **UndoManager** |
| Persistence | electron-store | **UserDefaults** + JSON in Application Support |

Dropped entirely: Electron, FFmpeg binary, Python, all native node addons, WebM intermediate,
the mux step.

Notable improvement available natively: **real click events via CGEventTap** (with Accessibility
permission), instead of the current macOS dwell-synthesis fallback. We keep dwell-synthesis as a
fallback when Accessibility is not granted.

## 3. Architecture (module map)

Designed for isolation: pure logic is separated from frameworks so it is independently
unit-testable and parity-locked against the JS reference.

```
Smoooth (macOS app)
├─ App/            SmooothApp (@main), scenes, menu bar, status-item tray, permissions glue
├─ Core/           PURE Swift, no AppKit — unit-tested, parity-locked
│   ├─ Models      FrameStyles, Background, CursorStyles, WebcamStyles, WebcamPosition,
│   │              ZoomRegion, CutRegion, SpeedRegion, MetaDataItem, Preset, CursorImage (Codable)
│   ├─ Defaults    All numeric defaults/ranges (from constants.ts) — exact values
│   ├─ Easing      easeOutQuint, easeInOutQuint, easeInOutCubic, Gentle/Bouncy spring (exact)
│   ├─ ZoomTransform   calculateZoomTransform (3-phase, EMA pan, bounded) — exact port
│   ├─ TimeRemap   mapExportTimeToSourceTime (cut/speed) — exact port
│   ├─ AutoZoom    generateZoomRegionsFromClicks + synthesizeClicksFromMoves — exact port
│   └─ Geometry    webcam rect-for-position, ruler intervals, color parse
├─ EditorModel/    @Observable store mirroring editorStore slices (project/playback/frame/
│                  timeline/preset/webcam/ui/audio) + actions; UndoManager integration
├─ Capture/        ScreenRecorder (SCStream→AVAssetWriter), WebcamRecorder, AudioRouting,
│                  MouseTracker (CGEventTap + cursor capture), PermissionsManager,
│                  RecordingCoordinator (orchestration + metadata write)
├─ Render/         SceneRenderer (compositor — exact drawScene port, Core Graphics),
│                  VideoExporter (frame loop + AVAssetWriter + audio remap), GifExporter (ImageIO),
│                  FrameSource (AVAssetImageGenerator, zero-tolerance exact seeks)
├─ UI/             SwiftUI: RecorderView, AreaSelectionView, EditorView (PreviewView, TimelineView,
│                  SidePanel tabs: General/Camera/Cursor/Audio/Animation/Settings), ExportModal,
│                  ExportProgressOverlay, PresetModal, color pickers, sliders, WindowControls
├─ Settings/       SettingsStore (UserDefaults keys mirrored), PresetStore (JSON), wallpapers
└─ Resources/      17 wallpapers (+thumbnails), app icons, Info.plist, entitlements
```

### Data flow

**Record:** RecorderView → RecordingCoordinator → PermissionsManager (screen/cam/mic/AX) →
ScreenRecorder(SCStream) + WebcamRecorder + MouseTracker start together; PTS-synced.
Stop → finalize AVAssetWriter(s) → write metadata JSON → open EditorView.

**Edit:** EditorModel holds project + style + timeline state. PreviewView renders the current
frame each tick: `SceneRenderer.render(state, mainFrame, webcamFrame, t, outW, outH)`. Timeline
edits mutate EditorModel (undoable). Auto-zoom generated from click metadata on load.

**Export:** ExportModal → VideoExporter computes export duration (cut/speed aware), loops frames:
`source_t = mapExportTimeToSourceTime(...)` → FrameSource exact-seeks main+webcam at source_t →
SceneRenderer composites → CVPixelBuffer → AVAssetWriter (H.264/HEVC, VideoToolbox). Audio track
remapped honoring cut/speed. GIF path: per-frame CGImage → ImageIO with palette/dither.

## 4. Parity checklist (full feature set to port)

**Capture:** fullscreen (multi-display selection); area selection (drag overlay); window capture
(SCContentFilter by window); webcam overlay source; microphone; system audio. Cursor hidden in
capture, re-drawn by compositor. Physical-pixel geometry; even width/height.

**Mouse metadata:** move/click/scroll with timestamps (seconds, synced to video start),
geometry-relative coords, per-event cursor image + hotspot, cursor scale (default 2×).

**Editor — frame & background:** aspect ratios 16:9, 16:10, 3:2, 9:16, 4:3, 3:4, 1:1; background
color; gradient (8 linear directions + radial circle-in/out); image upload; 17 bundled wallpapers;
padding (0–30, def 5), border radius (0–100, def 16), shadow (blur 0–100 def 35, offsetX −50..50
def 0, offsetY def 15, color rgba def 0.8 black), border (width 0–20 def 4, color def white 0.2).

**Cinematic zoom/pan:** auto + fixed modes; 5 easings (Smooth/Balanced/Dynamic/Gentle Spring/
Bouncy Spring); speed options Slow 1.5 / Mellow 1.0 / Quick 0.7 / Rapid 0.4 (transitionDuration);
zoom level 1–3 (def 1.5); EMA-smoothed pan (factor 0.1, 0.5s window); bounded pan; 3-phase
zoom-in/hold/zoom-out; auto-generate from click groups (pre 1.0s, post 0.9s, min 3.0s); apply-to-all.

**Cursor styles:** show/hide; drop shadow (blur def 6, x/y def 3, color 0.4 black); click ripple
(off by default, size 30, duration 0.5, color white 0.8); click scale (on, amount 0.8, duration
0.4, easing Balanced).

**Webcam styles:** shape circle/square/rectangle; size 10–50% (def 40); border radius 0–50 (def 35);
flip; shadow (blur 20, y 10, color 0.4); smart-position (on; lookahead 0.1s, transition 0.5s,
adjacency map); scale-on-zoom (on, amount 0.8).

**Timeline:** zoom/cut/speed regions; add at playhead; drag move + resize; delete; min region 0.1s,
delete-threshold 0.05s; z-index by duration (shorter on top); speed region default 1.5×; apply
speed/animation to all; trim start/end cut helpers; ruler with dynamic intervals; playhead;
timeline zoom.

**Playback:** play/pause, frame step (±1 frame), seek ±seconds, seek to prev/next frame.

**Audio:** volume 0–1 (def 1), mute. Applied in preview and export.

**Presets:** CRUD, default preset, apply, save-current-as, rename, persisted; last-active restored.

**App-level:** light/dark mode; import external video (mp4/mov/webm/mkv) for editing; undo/redo;
status-item tray during recording (Stop/Cancel); menu bar; permission prompts with deep links;
orphaned-recording cleanup; saving/countdown windows.

**Export:** MP4 (H.264; quality equiv to libx264 crf 15 tune animation → high-quality VT settings)
and GIF; resolutions 720p/1080p/2k by height (width from aspect ratio, even); fps; cut/speed-aware
duration; progress; cancel.

## 5. Key technical decisions

- **Compositor = Core Graphics (CGContext).** Near 1:1 mapping to the existing Canvas2D renderer
  (CGPath/`roundRect`, `clip`, `setShadow`, `draw(CGImage)`, CG gradients, arcs) → maximizes pixel
  parity. Preview renders off the main actor; if 60fps preview proves heavy at 2K, optimize hot
  paths with Core Image/Metal later. Export uses the same renderer for identical output.
- **Exact-frame source access = `AVAssetImageGenerator`** with `requestedTimeToleranceBefore/After
  = .zero` (mirrors the current seek-driven exact-frame export). Webcam via a second generator.
- **Encoder = AVAssetWriter + VideoToolbox**, H.264 High (HEVC optional). Map "crf 15 / high
  quality" to a high `AVVideoQualityKey`/bitrate. GIF via ImageIO with adaptive palette + dither.
- **Mouse = CGEventTap** for real move/click/scroll (Accessibility permission), capturing
  `NSCursor` image + hotspot per event; dwell-synthesis fallback when AX not granted.
- **Concurrency:** Swift 6 actors. Capture writers and the export loop run on dedicated actors;
  UI on `@MainActor`. AVAssetWriter pixel-buffer pool for export.
- **No sandbox initially** (screen capture + CGEventTap + arbitrary export paths are simplest
  unsandboxed). Hardened runtime + sandbox entitlements documented for the notarization step.
- **Project tooling:** an Xcode project so `xcodebuild` drives CI/QA. Generated from a
  `project.yml` via XcodeGen (installed if absent); fallback is a hand-authored `.xcodeproj`.
- **Repo layout:** new top-level `macos/` directory; the Electron app stays intact alongside it.

## 6. Testing / QA strategy (production-readiness gate)

1. **Unit tests (XCTest), parity-locked to JS:** easing curve values, zoom transform golden
   vectors, time-remap, auto-zoom grouping, dwell synthesis, ruler intervals, color parse, webcam
   rect positions, export-dimension math. Port the existing vitest cases where still meaningful.
2. **Build gate:** `xcodebuild` clean Debug + Release succeed; no errors; warnings triaged.
3. **Headless export test:** bundle a small sample mp4 + synthetic metadata; run VideoExporter;
   assert output is a valid H.264 mp4 of expected dimensions/duration; spot-check pixels against
   reference frames from the Electron compositor.
4. **UI launch smoke:** launch the app, screenshot recorder + editor, verify no crash, controls
   present and wired.
5. **Permission flows:** verify graceful prompts + deep links when screen/cam/mic/AX denied.
6. **Parallel QA subagents:** dispatch independent agents for (a) core-math parity verification,
   (b) compositor pixel parity, (c) export output validation, (d) UI launch + interaction,
   (e) code review. Aggregate findings; fix; re-verify.

Note: the gstack `/qa` skill targets web apps. For this native macOS app the operative analogs
are `verify` + `run` + parallel test subagents; full record→export E2E needs real TCC grants and
a live display, so the deterministic gate is unit + headless-export + launch-smoke, with manual
permission-grant runs documented.

## 7. Build sequence (phases)

1. Scaffold Xcode project, Info.plist (usage strings already enumerated), entitlements, app icon,
   wallpapers; empty SwiftUI app builds and launches.
2. Core models + pure algorithms + unit tests (parity-locked). ← correctness foundation
3. Capture engine (SCStream→AVAssetWriter, webcam, audio, CGEventTap, permissions) + metadata.
4. SceneRenderer compositor (CGContext) — parity with `drawScene`.
5. Editor UI: preview + timeline + side-panel tabs + presets + undo + playback + audio.
6. Export: FrameSource + VideoExporter + AVAssetWriter + GIF + progress/cancel.
7. Integration, polish, parallel QA subagents, fix-and-reverify.
8. Release build; document signing/notarization as the final pre-distribution step.

## 8. Risks

- **Compositor pixel parity** (shadows, gradients, rounded clip, cursor scale) — mitigated by
  using CGContext (closest analog) + reference-frame spot checks.
- **Preview performance at 2K/60fps** with CGContext — mitigated by off-main rendering; Metal
  fallback if needed.
- **Real-frame exact seeks** performance for long exports via AVAssetImageGenerator — batch with
  `generateCGImagesAsynchronously`; acceptable for offline export.
- **TCC permissions in automated QA** — deterministic gate avoids requiring grants; full E2E is a
  documented manual pass.
```
