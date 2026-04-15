import AppKit
import CoreGraphics
import Foundation

/// Tracks mouse position (~120Hz poll) and clicks (CGEventTap) for a specific recorded display.
///
/// Coordinate system: emitted positions are **display-local pixels with top-left origin**,
/// matching SCK video-frame coordinates.
///
/// Translation:
/// - `NSEvent.mouseLocation` is in AppKit's global space: bottom-left origin at the primary
///   display's bottom-left corner. We subtract the display's global origin and flip Y using the
///   display frame's height.
/// - `CGEvent.location` is already top-left origin in **global** display pixels. We subtract the
///   display's top-left origin (in top-left coordinates) to get display-local.
///
/// Requires Accessibility permission for `CGEventTap`; cursor polling works without it.
final class CursorTracker: @unchecked Sendable {

    var onCursorSample: ((CursorSample) -> Void)?
    var onClick: ((ClickEvent) -> Void)?

    private let clock: EventClock

    /// The recorded display's frame in AppKit global coords (bottom-left origin of primary).
    private let displayFrame: CGRect

    /// Same frame but in top-left-origin CG global coords (used for CGEvent.location translation).
    private let displayOriginTopLeft: CGPoint

    private var pollingTimer: DispatchSourceTimer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastPosition: CGPoint = .init(x: -1, y: -1)
    private let pollQueue = DispatchQueue(label: "com.cursorful.cursor.poll", qos: .userInteractive)

    init(clock: EventClock, displayFrame: CGRect) {
        self.clock = clock
        self.displayFrame = displayFrame
        // In CG top-left global coords, origin is the top edge of the display's screen rect.
        // The primary display's top edge is at y=0. A display positioned above the primary in
        // AppKit (y > primary.height) has a negative top-left-y in CG space.
        let primaryHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? displayFrame.height
        let topLeftY = primaryHeight - (displayFrame.origin.y + displayFrame.height)
        self.displayOriginTopLeft = CGPoint(x: displayFrame.origin.x, y: topLeftY)
    }

    // MARK: - Start / stop

    func start() {
        startPollingTimer()
        installEventTap()
        Log.events.info("CursorTracker started (display frame \(String(describing: self.displayFrame)))")
    }

    func stop() {
        pollingTimer?.cancel()
        pollingTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        Log.events.info("CursorTracker stopped")
    }

    // MARK: - Polling timer (120Hz supplement)

    private func startPollingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / 120.0))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .nanoseconds(500_000))
        timer.setEventHandler { [weak self] in
            self?.pollCursor()
        }
        timer.resume()
        self.pollingTimer = timer
    }

    private func pollCursor() {
        // `NSEvent.mouseLocation`: global AppKit coords (bottom-left origin of primary display).
        let mouse = NSEvent.mouseLocation
        let relX = mouse.x - displayFrame.origin.x
        let relYFromTop = (displayFrame.origin.y + displayFrame.height) - mouse.y
        let position = CGPoint(x: relX, y: relYFromTop)

        // Clip to the recorded display's rect — out-of-bounds samples add noise.
        guard position.x >= 0, position.y >= 0,
              position.x <= displayFrame.width, position.y <= displayFrame.height else {
            return
        }
        if position == lastPosition { return }
        lastPosition = position
        let time = clock.now()
        onCursorSample?(CursorSample(time: time, position: position))
    }

    // MARK: - Event tap

    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: userInfo
        ) else {
            Log.events.warning("CGEventTap failed — Accessibility permission missing?")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<CursorTracker>.fromOpaque(refcon).takeUnretainedValue()
        me.handleEvent(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // CGEvent.location is top-left-origin in **global** CG display coords.
        // Translate to display-local by subtracting the display's top-left origin.
        let global = event.location
        let local = CGPoint(x: global.x - displayOriginTopLeft.x,
                            y: global.y - displayOriginTopLeft.y)

        let ticks = event.timestamp
        let time = clock.time(fromCGEventTimestamp: ticks)

        let button: ClickEvent.Button
        let down: Bool
        switch type {
        case .leftMouseDown:  button = .left;   down = true
        case .leftMouseUp:    button = .left;   down = false
        case .rightMouseDown: button = .right;  down = true
        case .rightMouseUp:   button = .right;  down = false
        case .otherMouseDown: button = .middle; down = true
        case .otherMouseUp:   button = .middle; down = false
        default: return
        }

        let mods = event.flags.rawValue
        let click = ClickEvent(time: time, position: local, button: button,
                               modifiers: UInt(mods), isDown: down)
        onClick?(click)
    }
}
