import AppKit
import CoreGraphics
import Foundation

/// Tracks mouse position (120Hz) and clicks system-wide. Requires Accessibility permission for the
/// `CGEventTap`. Falls back to `NSEvent.mouseLocation` polling if the tap can't be created.
///
/// Coordinate system: delivered in "top-left origin" display pixels (matches SCK video frame
/// coordinates). AppKit's `NSEvent.mouseLocation` returns flipped coordinates which we flip once.
final class CursorTracker: @unchecked Sendable {

    var onCursorSample: ((CursorSample) -> Void)?
    var onClick: ((ClickEvent) -> Void)?

    private let clock: EventClock
    private var pollingTimer: DispatchSourceTimer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastPosition: CGPoint = .zero
    private let pollQueue = DispatchQueue(label: "com.cursorful.cursor.poll", qos: .userInteractive)

    init(clock: EventClock) {
        self.clock = clock
    }

    // MARK: - Start / stop

    func start() {
        startPollingTimer()
        installEventTap()
        Log.events.info("CursorTracker started")
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

    // MARK: - Polling timer (120Hz fallback / supplement)

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
        let flipped = NSEvent.mouseLocation
        // Convert from AppKit bottom-left to top-left display coordinates.
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let position = CGPoint(x: flipped.x, y: screenHeight - flipped.y)
        // Dedup identical positions to reduce JSONL noise (cursor idle case).
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
        let location = event.location
        let ticks = event.timestamp
        let time = clock.time(fromCGEventTimestamp: ticks)

        let button: ClickEvent.Button
        let down: Bool
        switch type {
        case .leftMouseDown:  button = .left; down = true
        case .leftMouseUp:    button = .left; down = false
        case .rightMouseDown: button = .right; down = true
        case .rightMouseUp:   button = .right; down = false
        case .otherMouseDown: button = .middle; down = true
        case .otherMouseUp:   button = .middle; down = false
        default: return
        }

        let mods = event.flags.rawValue
        let click = ClickEvent(time: time, position: location, button: button, modifiers: UInt(mods), isDown: down)
        onClick?(click)
    }
}
