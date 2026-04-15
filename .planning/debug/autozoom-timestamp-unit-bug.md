---
status: awaiting_human_verify
trigger: "auto-zoom STILL doesn't work in 0.2.5 — clicks received but no zoom fires"
created: 2026-04-15T01:00:00Z
updated: 2026-04-15T01:30:00Z
---

## Current Focus

hypothesis: RESOLVED — CGEventTimestamp is in nanoseconds; fix applied, all 21 tests pass, 0.2.6 DMG built
test: Build green, 21/21 tests pass including new regression tests
expecting: Fresh recording in 0.2.6 shows auto-zoom around each click in preview and export
next_action: Human verification with Smoooth-0.2.6.dmg

## Symptoms

expected: Fresh recording in 0.2.5 with clicks -> editor opens -> preview plays -> cinematic auto-zoom kicks in around each click
actual: Preview plays but no zoom ever appears. Same in exported MP4.
errors: no orange banner (Accessibility IS granted; clicks flowing into CGEventTap)
reproduction:
  1. Launch Smoooth 0.2.5
  2. Record, click ~5 times over 10 seconds
  3. Stop -> editor opens
  4. Preview plays smoothly but NO zoom visible
started: Third report of this issue. 0.2.3 wrong coords; 0.2.4 frozen preview; 0.2.5 fixed Accessibility detection; yet zoom still absent

## Eliminated

- hypothesis: Preview frozen
  evidence: Linear-read fix in 0.2.4 resolved this
  timestamp: prior session

- hypothesis: Accessibility permission missing / no click events captured
  evidence: Fixed in 0.2.5 (AXIsProcessTrusted check + orange banner). No banner appears in 0.2.5 recordings.
  timestamp: prior session

- hypothesis: AutoZoomPlanner algorithm is wrong
  evidence: 7 unit tests pass; algorithm is correct when given valid input
  timestamp: prior session

- hypothesis: CGEventTap silently failing (empty events.jsonl)
  evidence: events.jsonl from 0.2.5 recording contains 8 click events — tap is working
  timestamp: 2026-04-15T01:05:00Z

- hypothesis: zoomRegions not wired to renderer after generation
  evidence: EditorLoader.load line 218 assigns renderer.zoomRegions AFTER generateAutoZoom runs. Order is correct.
  timestamp: 2026-04-15T01:05:00Z

## Evidence

- timestamp: 2026-04-15T01:05:00Z
  checked: ~/Movies/Smoooth/Recordings/702C68C3.../events.jsonl and meta.json
  found: meta.json duration=15s. Click t values: 17463644, 17463649, 17463747... (all ~17.4 million seconds). Video duration = 15 seconds.
  implication: Click timestamps are ~1.16 million times larger than video duration. They are massively out of range.

- timestamp: 2026-04-15T01:08:00Z
  checked: EventClock.swift seconds(fromCGEventTimestamp:) at line 38
  found: Formula: Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / nanosPerSecond
    On Apple Silicon: numer=125, denom=3 (ratio ~41.67)
    This formula treats ticks as mach_absolute_time units and converts to nanoseconds, then to seconds.
    BUT: CGEventGetTimestamp returns NANOSECONDS already (confirmed by Apple developer forums and our data).
    Applying the 41.67x multiplier to nanoseconds produces a value 41.67x too large in nanoseconds, then / 1e9 = 41.67x too large in seconds.
  implication: BUG IS HERE. The fix is to divide by 1e9 only.

- timestamp: 2026-04-15T01:10:00Z
  checked: Math verification with known values
  found: stored click t = 17463644.859 (session-relative). Reversing: raw CGEventTimestamp in ns = 4.294e14.
    raw / 1e9 = 429433.811 seconds. Session-relative = 429433.811 - 429430.606 = 3.205 seconds.
    3.205s is within [0, 15s] duration. CONFIRMED.
  implication: Fix confirmed: drop timebase multiply in seconds(fromCGEventTimestamp:).

- timestamp: 2026-04-15T01:12:00Z
  checked: EventClockTests.swift testCGEventTimestampRoundTripPrecise
  found: Test passes mach_absolute_time() (mach ticks) into seconds(fromCGEventTimestamp:) and compares
    to nowSeconds() which also converts mach ticks via timebase. Since both sides use the SAME (wrong)
    interpretation, the test passes — it does not catch the bug.
    The test needs to use a known nanosecond value and verify the output.
  implication: Test must be rewritten to use nanoseconds as input (matching CGEventTimestamp behavior).

- timestamp: 2026-04-15T01:14:00Z
  checked: nowSeconds() and anchor path in RecordingCoordinator
  found: nowSeconds() correctly uses mach_absolute_time() * timebase. anchor() comes from CMSampleBuffer
    PTS which is in seconds. These are both correct. Only seconds(fromCGEventTimestamp:) is wrong.
  implication: Fix is isolated to one function.

## Resolution

root_cause: EventClock.seconds(fromCGEventTimestamp:) applies the mach timebase multiplier (125/3 on Apple Silicon) to a value that is already in nanoseconds. CGEventGetTimestamp returns nanoseconds (absolute ns since boot), NOT mach ticks. The timebase multiply inflates the timestamp ~41.67x. After subtracting sessionStartSec (which is in correct mach seconds = ~429430s), the resulting session-relative click time is ~17,463,644 seconds — far beyond the recording duration. AutoZoomPlanner.evaluate() sees no zoom region active at any playback time in [0, 15s], so it always returns .identity.

fix: In EventClock.seconds(fromCGEventTimestamp:), replace the timebase multiply with a direct /1e9 division:
  BEFORE: Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / nanosPerSecond
  AFTER:  Double(ticks) / nanosPerSecond
Also fix testCGEventTimestampRoundTripPrecise to test with nanoseconds (not mach ticks).

verification:
  Build: SUCCEEDED (Release, arm64)
  Tests: 21/21 passed (7 AutoZoomPlanner + 6 EventClock + 4 MetalUniforms + 4 TimingFunction)
  New tests: testCGEventTimestampIsNanosecondsNotMachTicks (pins 5e9 ns → 5.0s, fails with old formula)
             testCGEventTimestampRoundTripPrecise rewritten (uses ns input, not mach ticks)
  Version: 0.2.6 written to Info.plist (CFBundleVersion=6)
  DMG: dist/Smoooth-0.2.6.dmg (4.0 MB, replaces 0.2.5)
  Awaiting human verification: zoom fires on fresh recording
files_changed:
  - Cursorful/Core/Capture/EventClock.swift
  - CursorfulTests/EventClockTests.swift
  - Cursorful/App/Info.plist
