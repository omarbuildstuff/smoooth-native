# Smoooth Native Swift — Foundation Implementation Plan (Phase 1–2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the native macOS Swift project (builds + launches an empty SwiftUI app) and a parity-locked, fully unit-tested pure-Swift Core library porting Smoooth's deterministic algorithms (easing, zoom transform, time remap, auto-zoom, geometry).

**Architecture:** Two units under `macos/`: (1) `SmooothCore` — a SwiftPM library + XCTest suite holding all framework-free logic, runnable headlessly via `swift test`; (2) `Smoooth` — a SwiftUI app (XcodeGen-generated `.xcodeproj`) that depends on `SmooothCore`. Parity is enforced by golden vectors dumped from the existing JS via Node and asserted in Swift.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest, XcodeGen, SwiftUI, macOS 26 SDK, Node 22 (reference-vector generation only).

This is the first of several subsystem plans. Follow-on plans (Capture, Render/Export, Editor UI, QA) are authored at execution time per the spec's subsystem decomposition: `docs/superpowers/specs/2026-05-28-smoooth-swift-native-rewrite-design.md`.

---

## File Structure

```
macos/
├─ SmooothCore/
│  ├─ Package.swift
│  ├─ Sources/SmooothCore/
│  │  ├─ Models.swift           # Codable value types (regions, styles, metadata, preset)
│  │  ├─ Defaults.swift         # exact numeric defaults/ranges from constants.ts
│  │  ├─ Easing.swift           # 5 easing curves + EasingMap
│  │  ├─ ZoomTransform.swift    # calculateZoomTransform (+ helpers)
│  │  ├─ TimeRemap.swift        # mapExportTimeToSourceTime
│  │  ├─ AutoZoom.swift         # generateZoomRegions + synthesizeClicksFromMoves
│  │  └─ Geometry.swift         # webcam rect-for-position, ruler intervals, color parse, export dims
│  └─ Tests/SmooothCoreTests/
│     ├─ Fixtures/vectors.json  # golden vectors dumped from JS
│     ├─ EasingTests.swift
│     ├─ ZoomTransformTests.swift
│     ├─ TimeRemapTests.swift
│     ├─ AutoZoomTests.swift
│     └─ GeometryTests.swift
├─ Smoooth/
│  ├─ project.yml               # XcodeGen spec
│  ├─ Sources/
│  │  ├─ SmooothApp.swift       # @main App
│  │  └─ ContentView.swift      # placeholder
│  ├─ Resources/                # wallpapers (copied from ../../public/wallpapers), icon
│  └─ Supporting/
│     ├─ Info.plist             # TCC usage strings
│     └─ Smoooth.entitlements
└─ scripts/
   └─ dump-reference-vectors.mjs  # runs JS algos, writes vectors.json
```

---

## Phase 1 — Scaffold

### Task 1: SmooothCore package skeleton

**Files:** Create `macos/SmooothCore/Package.swift`, `macos/SmooothCore/Sources/SmooothCore/SmooothCore.swift`, `macos/SmooothCore/Tests/SmooothCoreTests/SmokeTests.swift`

- [ ] **Step 1:** Write `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmooothCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SmooothCore", targets: ["SmooothCore"])],
    targets: [
        .target(name: "SmooothCore"),
        .testTarget(name: "SmooothCoreTests", dependencies: ["SmooothCore"],
                    resources: [.copy("Fixtures/vectors.json")]),
    ]
)
```

- [ ] **Step 2:** Write placeholder `SmooothCore.swift`: `public enum SmooothCore { public static let version = "0.1.0" }`
- [ ] **Step 3:** Write `SmokeTests.swift` asserting `SmooothCore.version == "0.1.0"`. Create empty `Tests/SmooothCoreTests/Fixtures/vectors.json` = `{}` so the resource copy resolves.
- [ ] **Step 4:** Run `cd macos/SmooothCore && swift test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(macos): SmooothCore package skeleton`.

### Task 2: App project via XcodeGen (builds + launches)

**Files:** Create `macos/Smoooth/project.yml`, `Sources/SmooothApp.swift`, `Sources/ContentView.swift`, `Supporting/Info.plist`, `Supporting/Smoooth.entitlements`.

- [ ] **Step 1:** `project.yml` — single macOS app target `Smoooth`, deployment 26.0 (fallback 14.0), bundle id `com.smoooth.app`, local package dependency on `../SmooothCore`, Info.plist + entitlements paths, Resources folder. (Exact YAML written at execution; XcodeGen `name/targets/packages` schema.)
- [ ] **Step 2:** `Info.plist` includes the five usage strings already defined in the Electron `package.json` (`NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `NSCameraUsageDescription`, `NSAudioCaptureUsageDescription`, `NSSystemAudioUsageDescription`) + `LSMinimumSystemVersion`.
- [ ] **Step 3:** Minimal `SmooothApp.swift` (`@main struct SmooothApp: App { var body: some Scene { WindowGroup { ContentView() } } }`) and `ContentView.swift` showing app name + `SmooothCore.version` (proves the package link).
- [ ] **Step 4:** `cd macos/Smoooth && xcodegen generate` then `xcodebuild -project Smoooth.xcodeproj -scheme Smoooth -configuration Debug -destination 'platform=macOS' build`. Expected: BUILD SUCCEEDED.
- [ ] **Step 5:** Add `macos/Smoooth/Smoooth.xcodeproj` to `.gitignore` (generated); commit sources + `project.yml`: `feat(macos): SwiftUI app scaffold (XcodeGen) linking SmooothCore`.

### Task 3: Reference-vector generator

**Files:** Create `macos/scripts/dump-reference-vectors.mjs`.

- [ ] **Step 1:** Node ESM script that imports/duplicates the JS reference functions and writes `macos/SmooothCore/Tests/SmooothCoreTests/Fixtures/vectors.json` with arrays of `{input, output}` for: easing (each curve at t=0,0.1,…,1.0), zoom transform (a fixed metadata set + region at sampled times), time remap (a duration + cut/speed set at sampled export times), auto-zoom (a click set → regions). Source of truth = `src/lib/easing.ts`, `transform.ts`, `utils.ts`, `store/slices/timelineSlice.ts`.
- [ ] **Step 2:** Run `node macos/scripts/dump-reference-vectors.mjs`; verify `vectors.json` is non-trivial.
- [ ] **Step 3:** Commit `test(macos): JS reference vectors for parity tests`.

---

## Phase 2 — Parity-locked Core (TDD)

> Each task: write Swift test asserting against `vectors.json` (or closed-form), run → fail, port the algorithm, run → pass, commit. Ports must reproduce the JS math exactly (same formulas, same clamping order).

### Task 4: Models

**Files:** Create `Sources/SmooothCore/Models.swift`, `Tests/SmooothCoreTests/ModelsTests.swift`.

- [ ] **Step 1:** Test: round-trip `Codable` decode of a sample metadata JSON (fields `timestamp,x,y,type,button,pressed,cursorImageKey`) and a `ZoomRegion`; assert fields. 
- [ ] **Step 2:** Run `swift test --filter ModelsTests` → FAIL (types missing).
- [ ] **Step 3:** Define value types mirroring `src/types/index.ts`: `MetaDataItem`, `EventType` enum (`click/move/scroll`), `ZoomRegion`, `CutRegion`, `SpeedRegion`, `Background`(+`BackgroundType`), `FrameStyles`, `CursorStyles`, `WebcamStyles`, `WebcamPosition`(+`Pos` enum), `WebcamShape`, `Preset`, `AspectRatio` enum (raw values `16:9`…). All `Codable, Equatable, Sendable`.
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit `feat(core): data models`.

### Task 5: Defaults

**Files:** Create `Sources/SmooothCore/Defaults.swift`, `Tests/.../DefaultsTests.swift`.

- [ ] **Step 1:** Test asserts exact values: `Defaults.Frame.paddingDefault == 5`, `radiusDefault == 16`, shadow blur 35 / offsetY 15 / opacity 0.8, border width 4; camera size 40, smartPosition transition 0.5, scaleOnZoomAmount 0.8; zoom level 1.5, duration 3.0, speedOptions Slow 1.5/Mellow 1.0/Quick 0.7/Rapid 0.4, autoZoom pre 1.0 / post 0.9 / min 3.0; cursor scale 2, click-scale amount 0.8 duration 0.4; resolutions 720p=1280×720,1080p=1920×1080,2k=2560×1440.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Port `src/lib/constants.ts` into nested enums/structs with these exact values. **Step 4:** PASS. **Step 5:** Commit `feat(core): defaults/constants`.

### Task 6: Easing

**Files:** Create `Sources/SmooothCore/Easing.swift`, `Tests/.../EasingTests.swift`.

- [ ] **Step 1:** Test loads `vectors.json` easing section; for each curve+t, assert `Easing.map[name](t)` ≈ expected within `1e-9` (closed-form) / `1e-6` (springs). Also assert all curves map 0→0 and 1→1.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Port `easeOutQuint`, `easeInOutQuint`, `easeInOutCubic`, and `createSpringEasing(tension,friction,mass)` exactly (under-/critically-damped branches), expose `EasingMap`: Smooth/Balanced/Dynamic/Gentle Spring (180,30,1)/Bouncy Spring (380,20,1). **Step 4:** PASS. **Step 5:** Commit `feat(core): easing curves (parity-locked)`.

### Task 7: ZoomTransform

**Files:** Create `Sources/SmooothCore/ZoomTransform.swift`, `Tests/.../ZoomTransformTests.swift`.

- [ ] **Step 1:** Test loads zoom-transform vectors (a metadata array + one auto + one fixed region, sampled across all 3 phases) and asserts `scale/translateX/translateY/transformOrigin` match within `1e-6`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Port `transform.ts`: `lerp`, `findLastMetadataIndex` (binary search), `getSmoothedMousePosition` (EMA factor 0.1, 0.5s window), `calculateBoundedPan`, `getTransformOrigin`, `calculateZoomTransform` (3-phase). Return a struct `ZoomTransformResult { scale; translateX; translateY; originX; originY }` (originX/Y as 0–1; UI formats the `%` string). **Step 4:** PASS. **Step 5:** Commit `feat(core): cinematic zoom transform (parity-locked)`.

### Task 8: TimeRemap

**Files:** Create `Sources/SmooothCore/TimeRemap.swift`, `Tests/.../TimeRemapTests.swift`.

- [ ] **Step 1:** Test loads time-remap vectors (duration + cut + speed regions; sampled export times) asserting source time within `1e-9`; include a pure-passthrough case (no regions ⇒ identity) and a cut-at-start case.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Port `mapExportTimeToSourceTime` exactly (event set, sort/filter, segment loop, cut skip, speed division, clamp). Add `exportDuration(duration, cuts, speeds)` (subtract cuts; speed ⇒ −dur +dur/speed). **Step 4:** PASS. **Step 5:** Commit `feat(core): export time remap (parity-locked)`.

### Task 9: AutoZoom

**Files:** Create `Sources/SmooothCore/AutoZoom.swift`, `Tests/.../AutoZoomTests.swift`.

- [ ] **Step 1:** Test loads auto-zoom vectors (click set + geometry + duration → expected region count, startTimes, durations, targetX/Y) asserting equality; plus a no-clicks→synthesize case.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Port `generateZoomRegionsFromClicks` (group gap = `AUTO_ZOOM_MIN_DURATION`, pre/post offsets, min/clamped duration, targetX/Y = x/width−0.5) and `synthesizeClicksFromMoves` (PAUSE_RADIUS 15, MIN 0.1, MAX 2.5). Pure function form: `AutoZoom.generate(metadata:geometry:duration:) -> [ZoomRegion]`. **Step 4:** PASS. **Step 5:** Commit `feat(core): auto-zoom generation (parity-locked)`.

### Task 10: Geometry

**Files:** Create `Sources/SmooothCore/Geometry.swift`, `Tests/.../GeometryTests.swift`.

- [ ] **Step 1:** Tests: `webcamRect(for:.bottomRight, …)` matches the 8-position formula (edgePadding = min(out)·0.02); `rulerInterval(pixelsPerSecond:)` picks nice intervals; `rgbaToComponents("rgba(255,128,0,0.5)")` → (255,128,0,0.5); `exportDimensions(.p1080, .r9x16)` → height 1920·? — assert even width derivation (height-based: baseHeight=1080, width=round(1080·9/16)=608, even).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Port `getWebcamRectForPosition`, `calculateRulerInterval`, color parse, and export-dimension math (`RendererPage` lines 122–127: width=round(baseHeight·ratioW/ratioH), bump to even; height=baseHeight). **Step 4:** PASS. **Step 5:** Commit `feat(core): geometry + color + export-dimension helpers`.

### Task 11: Phase-2 gate

- [ ] **Step 1:** Run full `swift test` — all suites PASS.
- [ ] **Step 2:** Run `xcodebuild … build` — app still builds (links updated Core).
- [ ] **Step 3:** Commit any fixups; tag note in plan. Foundation complete.

---

## Self-Review

- **Spec coverage (this plan's scope):** scaffold ✓ (T1–2), reference vectors ✓ (T3), models ✓ (T4), defaults ✓ (T5), easing ✓ (T6), zoom transform ✓ (T7), time remap ✓ (T8), auto-zoom ✓ (T9), geometry/color/export-dims ✓ (T10), gate ✓ (T11). Out-of-scope-for-this-plan (own follow-on plans): Capture, SceneRenderer/Export, Editor UI, QA — explicitly deferred per subsystem decomposition.
- **Placeholders:** XcodeGen `project.yml` and the Node dump script bodies are described, not literal — acceptable because both are environment-generated and validated by their run-step (build succeeds / vectors.json non-trivial); exact contents authored at execution.
- **Type consistency:** `ZoomTransformResult`, `AutoZoom.generate`, `exportDuration`, `exportDimensions`, `EasingMap` names are referenced consistently and consumed by later subsystem plans (renderer/exporter).
```
