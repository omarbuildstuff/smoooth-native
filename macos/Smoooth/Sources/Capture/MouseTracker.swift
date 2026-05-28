import Foundation
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A raw, screen-global mouse sample emitted by `MouseTracker`. Coordinates are
/// in **physical pixels** with a top-left origin (already converted from the
/// AppKit / Core Graphics coordinate spaces), so they line up with the physical
/// `RecordingGeometry`. Timestamps are absolute wall-clock seconds; the
/// coordinator rebases them so the first video frame ≈ t=0.
///
/// This mirrors the per-event shape the Electron mouse-tracker emitted
/// (`{ timestamp, x, y, type, button?, pressed?, cursorImageKey }`).
public struct RawMouseSample: Sendable {
    public enum Kind: Sendable { case move, click, scroll }
    public var timestamp: Double      // seconds, absolute (wall clock)
    public var x: Double              // physical pixels, top-left origin
    public var y: Double
    public var kind: Kind
    public var button: String?        // "left" | "right" | "middle" for clicks
    public var pressed: Bool?         // true=down, false=up (clicks only)
    public var cursorImageKey: String
}

/// A captured cursor image — RGBA pixel bytes plus hotspot, keyed per distinct
/// cursor shape. The `image` byte layout is exactly what the editor decodes via
/// `new ImageData(new Uint8ClampedArray(image), width, height)` (see
/// src/lib/utils.ts prepareCursorBitmaps): width*height*4 bytes, RGBA.
public struct CapturedCursorImage: Sendable {
    public var width: Int
    public var height: Int
    public var xhot: Int
    public var yhot: Int
    public var image: [UInt8]
}

/// Captures global mouse activity during a recording using a `CGEventTap`, with
/// an `NSEvent` global-monitor fallback when the tap can't be installed (no
/// Accessibility grant, or sandbox restrictions). For every event it also snaps
/// the current system cursor image (deduplicated by a content key) so the editor
/// can overlay the real pointer.
///
/// Thread-safety: all shared mutable state lives behind `lock`. The CGEventTap
/// runs on its own run-loop thread; the steady-cadence move sampler runs on a
/// dedicated timer queue. Neither ever re-enters the lock recursively.
/// `@unchecked Sendable` is therefore safe.
public final class MouseTracker: @unchecked Sendable {

    // MARK: - Configuration

    /// Frames per second for the synthetic move stream (the CGEventTap delivers
    /// raw moves; we also poll to guarantee a steady cadence even when the
    /// pointer is still, matching MOUSE_RECORDING_FPS = 50 from the original).
    private let moveSampleFPS: Double

    // MARK: - Shared state (guarded by `lock`)

    private let lock = NSLock()
    private var samples: [RawMouseSample] = []
    private var cursorImages: [String: CapturedCursorImage] = [:]
    private var lastCursorKey: String = "arrow"
    private var tapRunLoop: CFRunLoop?

    // MARK: - Tap machinery (touched only on start/stop)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var pollTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.smoooth.mousetracker.timer")

    // Main-thread cursor refresher. NSCursor is AppKit/main-thread-only, so the
    // current cursor shape is snapshotted on the main run loop and stored into the
    // lock-guarded `cursorImages` / `lastCursorKey`. The tap and poll threads never
    // touch NSCursor; they only read the most-recent `lastCursorKey` under `lock`.
    private var cursorRefreshTimer: Timer?

    // NSEvent fallback monitors.
    private var globalMonitors: [Any] = []
    private var usingFallback = false

    public init(moveSampleFPS: Double = 50) {
        self.moveSampleFPS = moveSampleFPS
    }

    // MARK: - Public API

    /// Begins capturing. Returns `true` if either the CGEventTap or the NSEvent
    /// fallback came up; `false` only if neither could be installed. Mirrors the
    /// Electron tracker's `start(): Promise<boolean>` contract (a `false` there
    /// aborts the recording).
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        cursorImages.removeAll(keepingCapacity: true)
        lastCursorKey = "arrow"
        lock.unlock()

        if installEventTap() {
            usingFallback = false
        } else if installFallbackMonitors() {
            usingFallback = true
        } else {
            return false
        }

        // Seed an initial cursor capture and start the main-thread refresher so
        // there's always at least one image. NSCursor must only be read on the
        // main thread; the tap/poll threads reference the captured key instead.
        startCursorRefresher()
        startPollingMoves()
        return true
    }

    /// Stops capturing and tears down all machinery. Safe to call repeatedly.
    public func stop() {
        pollTimer?.cancel()
        pollTimer = nil

        // Tear down the main-thread cursor refresher on the main thread (Timer is
        // main-thread-affined here). Capture it under the lock to avoid racing the
        // setup that may still be hopping onto the main queue.
        let refresher = cursorRefreshTimer
        cursorRefreshTimer = nil
        if let refresher {
            if Thread.isMainThread {
                refresher.invalidate()
            } else {
                DispatchQueue.main.async { refresher.invalidate() }
            }
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        lock.lock()
        let loop = tapRunLoop
        lock.unlock()
        if let source = runLoopSource, let loop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopStop(loop)
        }
        runLoopSource = nil
        eventTap = nil
        tapThread = nil
        lock.lock()
        tapRunLoop = nil
        lock.unlock()

        for monitor in globalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors.removeAll()
    }

    /// Snapshot of everything captured so far. Returned after `stop()` by the
    /// coordinator to build the metadata JSON.
    public func drain() -> (samples: [RawMouseSample], cursors: [String: CapturedCursorImage]) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, cursorImages)
    }

    // MARK: - CGEventTap install

    private static let interestedMask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    private func installEventTap() -> Bool {
        // The C callback can't capture context, so we pass `self` (unretained)
        // through the `userInfo` pointer and trampoline back.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<MouseTracker>.fromOpaque(userInfo).takeUnretainedValue()
            tracker.handleTapEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.interestedMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        // Run the tap on a dedicated thread so it keeps firing regardless of the
        // app's main run-loop activity (e.g. when the recorder window is hidden).
        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else { return }
            let loop = CFRunLoopGetCurrent()
            self.lock.lock()
            self.tapRunLoop = loop
            self.lock.unlock()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.smoooth.mousetracker.tap"
        self.tapThread = thread
        thread.start()
        return true
    }

    // MARK: - NSEvent fallback

    private func installFallbackMonitors() -> Bool {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let upMask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        let scrollMask: NSEvent.EventTypeMask = [.scrollWheel]

        let moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask) { [weak self] event in
            self?.handleFallbackEvent(event, kind: .move)
        }
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: downMask) { [weak self] event in
            self?.handleFallbackEvent(event, kind: .click, pressed: true)
        }
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: upMask) { [weak self] event in
            self?.handleFallbackEvent(event, kind: .click, pressed: false)
        }
        let scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: scrollMask) { [weak self] event in
            self?.handleFallbackEvent(event, kind: .scroll)
        }

        globalMonitors = [moveMonitor, downMonitor, upMonitor, scrollMonitor].compactMap { $0 }
        return !globalMonitors.isEmpty
    }

    // MARK: - Steady move polling

    private func startPollingMoves() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let interval = 1.0 / moveSampleFPS
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Poll-driven move uses the HID cursor location so it's correct even
            // when no tap/monitor move event has arrived (pointer held still).
            let location = self.currentGlobalPixelLocation()
            let key = self.currentCursorKey()
            let sample = RawMouseSample(
                timestamp: Self.nowSeconds(),
                x: location.x,
                y: location.y,
                kind: .move,
                button: nil,
                pressed: nil,
                cursorImageKey: key
            )
            self.appendSample(sample)
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Event handling

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        let kind: RawMouseSample.Kind
        var pressed: Bool? = nil
        var button: String? = nil

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            kind = .move
        case .scrollWheel:
            kind = .scroll
        case .leftMouseDown:
            kind = .click; pressed = true; button = "left"
        case .leftMouseUp:
            kind = .click; pressed = false; button = "left"
        case .rightMouseDown:
            kind = .click; pressed = true; button = "right"
        case .rightMouseUp:
            kind = .click; pressed = false; button = "right"
        case .otherMouseDown:
            kind = .click; pressed = true; button = mapOtherButton(event)
        case .otherMouseUp:
            kind = .click; pressed = false; button = mapOtherButton(event)
        default:
            return
        }

        // CGEvent.location is in global display points, top-left origin.
        let pixel = pixelFromGlobalPoint(event.location)
        let key = currentCursorKey()

        let sample = RawMouseSample(
            timestamp: Self.nowSeconds(),
            x: pixel.x,
            y: pixel.y,
            kind: kind,
            button: button,
            pressed: pressed,
            cursorImageKey: key
        )
        appendSample(sample)
    }

    private func handleFallbackEvent(_ event: NSEvent, kind: RawMouseSample.Kind, pressed: Bool? = nil) {
        var button: String? = nil
        if kind == .click {
            switch event.type {
            case .leftMouseDown, .leftMouseUp: button = "left"
            case .rightMouseDown, .rightMouseUp: button = "right"
            default: button = event.buttonNumber == 2 ? "middle" : "unknown"
            }
        }

        // NSEvent global monitors deliver no usable window-relative point, so use
        // the HID cursor location (global, top-left origin in CGEvent space).
        let pixel = currentGlobalPixelLocation()
        let key = currentCursorKey()

        let sample = RawMouseSample(
            timestamp: Self.nowSeconds(),
            x: pixel.x,
            y: pixel.y,
            kind: kind,
            button: button,
            pressed: pressed,
            cursorImageKey: key
        )
        appendSample(sample)
    }

    private func mapOtherButton(_ event: CGEvent) -> String {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        return number == 2 ? "middle" : "unknown"
    }

    private func appendSample(_ sample: RawMouseSample) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    // MARK: - Cursor capture

    /// Returns the key of the most-recently main-thread-captured cursor shape.
    /// Called from the CGEventTap run-loop thread and the poll `timerQueue`; it
    /// only touches `lastCursorKey` under `lock` and never reads NSCursor (which
    /// is AppKit/main-thread-only).
    private func currentCursorKey() -> String {
        lock.lock(); defer { lock.unlock() }
        return lastCursorKey
    }

    /// Installs a main-thread timer that periodically snapshots the current system
    /// cursor. NSCursor must only be read on the main thread, so all NSCursor
    /// access is confined here. The refresh cadence matches the move sampler so a
    /// shape change is picked up within one sample. Scheduling happens on the main
    /// queue (no blocking `sync`), which is why the tap thread can never deadlock
    /// against it.
    private func startCursorRefresher() {
        let interval = 1.0 / moveSampleFPS
        let install = { [weak self] in
            guard let self else { return }
            // Seed immediately so there's at least one image before the first tick.
            self.refreshCursorOnMain()
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.refreshCursorOnMain()
            }
            timer.tolerance = interval * 0.25
            self.cursorRefreshTimer = timer
        }
        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.async(execute: install)
        }
    }

    /// Snapshots the current system cursor and stores it keyed by a content hash
    /// so each distinct shape is recorded once (the Electron tracker did the same
    /// with a SHA-1 of the cursor bytes). MUST run on the main thread.
    private func refreshCursorOnMain() {
        let cursor = NSCursor.currentSystem ?? NSCursor.current
        let image = cursor.image
        let hotSpot = cursor.hotSpot

        guard let rgba = Self.rgbaBytes(from: image) else { return }
        let key = Self.contentKey(width: rgba.width, height: rgba.height, bytes: rgba.bytes)

        // The hotspot is reported in points but the RGBA bitmap is in backing
        // pixels (Retina cursors render at 2x). Scale the hotspot into pixel space
        // so the editor's pixel-space hotspot subtraction lands on the cursor tip.
        let pointWidth = image.size.width
        let pointHeight = image.size.height
        let xScale = pointWidth > 0 ? CGFloat(rgba.width) / pointWidth : 1
        let yScale = pointHeight > 0 ? CGFloat(rgba.height) / pointHeight : 1

        lock.lock()
        lastCursorKey = key
        if cursorImages[key] == nil {
            cursorImages[key] = CapturedCursorImage(
                width: rgba.width,
                height: rgba.height,
                xhot: Int((hotSpot.x * xScale).rounded()),
                yhot: Int((hotSpot.y * yScale).rounded()),
                image: rgba.bytes
            )
        }
        lock.unlock()
    }

    // MARK: - Coordinate + time helpers

    /// HID cursor location converted to physical pixels with a top-left origin.
    /// `CGEvent(source:)?.location` reports global display points (top-left), so
    /// we scale by the backing factor of the display under the pointer.
    private func currentGlobalPixelLocation() -> CGPoint {
        let point = CGEvent(source: nil)?.location ?? .zero
        return pixelFromGlobalPoint(point)
    }

    /// Converts a global point (top-left origin, points) to physical pixels using
    /// the scale factor of the screen the point falls on. This matches the
    /// Electron path that multiplied DIP coordinates by `display.scaleFactor`.
    private func pixelFromGlobalPoint(_ point: CGPoint) -> CGPoint {
        let scale = Self.scaleFactor(forGlobalTopLeftPoint: point)
        return CGPoint(x: (point.x * scale).rounded(), y: (point.y * scale).rounded())
    }

    /// Finds the backing scale factor of the display containing `point`, where
    /// `point` is in global, top-left-origin point space (the CGEvent space).
    private static func scaleFactor(forGlobalTopLeftPoint point: CGPoint) -> CGFloat {
        // NSScreen frames are bottom-left origin; flip the y against the primary
        // (menu-bar) screen height to test containment.
        guard let primary = NSScreen.screens.first else { return 1 }
        let primaryHeight = primary.frame.height
        let flipped = CGPoint(x: point.x, y: primaryHeight - point.y)
        for screen in NSScreen.screens where screen.frame.contains(flipped) {
            return screen.backingScaleFactor
        }
        return primary.backingScaleFactor
    }

    private static func nowSeconds() -> Double {
        // Wall-clock seconds. The coordinator rebases against the writer session
        // start so the first frame lands at ~t=0.
        Date().timeIntervalSince1970
    }

    // MARK: - Image conversion

    private struct RGBA {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// Renders an `NSImage` into tightly packed RGBA8 (premultiplied-last) bytes
    /// suitable for `ImageData` on the editor side.
    private static func rgbaBytes(from image: NSImage) -> RGBA? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let didDraw: Bool = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        return RGBA(width: width, height: height, bytes: buffer)
    }

    /// Stable content key for a cursor image. FNV-1a over the pixel bytes plus
    /// dimensions — deterministic and dependency-free (the original used SHA-1;
    /// any stable hash works since the key is opaque to the editor).
    private static func contentKey(width: Int, height: Int, bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        func mix(_ value: Int) {
            var v = UInt64(bitPattern: Int64(value))
            for _ in 0..<8 {
                hash ^= (v & 0xff)
                hash = hash &* prime
                v >>= 8
            }
        }
        mix(width)
        mix(height)
        // Sample the buffer (stride) to keep hashing cheap on large cursors while
        // staying sensitive to shape changes.
        let stride = Swift.max(1, bytes.count / 4096)
        var index = 0
        while index < bytes.count {
            hash ^= UInt64(bytes[index])
            hash = hash &* prime
            index += stride
        }
        return String(format: "%016llx", hash)
    }
}
