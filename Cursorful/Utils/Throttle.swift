import Foundation

/// Simple leading-edge throttle. Calls `action` at most once per `interval`.
final class Throttle {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private var lastFire: TimeInterval = 0
    private var pending: DispatchWorkItem?

    init(interval: TimeInterval, queue: DispatchQueue = .main) {
        self.interval = interval
        self.queue = queue
    }

    func call(_ action: @escaping () -> Void) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFire
        pending?.cancel()
        if elapsed >= interval {
            lastFire = now
            queue.async(execute: action)
        } else {
            let item = DispatchWorkItem { [weak self] in
                self?.lastFire = CFAbsoluteTimeGetCurrent()
                action()
            }
            pending = item
            queue.asyncAfter(deadline: .now() + (interval - elapsed), execute: item)
        }
    }
}
