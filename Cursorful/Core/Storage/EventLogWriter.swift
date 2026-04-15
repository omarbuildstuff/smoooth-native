import Foundation
import CoreMedia

/// Append-only JSONL writer for cursor samples and click events.
///
/// One JSON object per line. Types are discriminated by a `"type"` field:
///   {"type":"cursor","t":0.123,"x":100,"y":200}
///   {"type":"click","t":0.234,"x":100,"y":200,"button":"left","down":true,"mods":0}
///
/// Writes are serialized on a dedicated queue. Buffering is done at the FileHandle layer; we flush
/// on close to guarantee durability without per-event fsync.
final class EventLogWriter: @unchecked Sendable {
    private let url: URL
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "com.cursorful.events.writer", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func writeCursor(_ sample: CursorSample) {
        let line = CursorLine(t: sample.time.secondsOrZero, x: sample.position.x, y: sample.position.y)
        append(line)
    }

    func writeClick(_ event: ClickEvent) {
        let line = ClickLine(
            t: event.time.secondsOrZero,
            x: event.position.x,
            y: event.position.y,
            button: event.button.rawValue,
            down: event.isDown,
            mods: event.modifiers
        )
        append(line)
    }

    private func append<T: Encodable>(_ line: T) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle,
                  var data = try? self.encoder.encode(line) else { return }
            data.append(0x0A) // newline
            try? handle.write(contentsOf: data)
        }
    }

    func close() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    deinit { close() }

    // Line models: compact field names for smaller files
    private struct CursorLine: Encodable { let type = "cursor"; let t: Double; let x: CGFloat; let y: CGFloat }
    private struct ClickLine: Encodable {
        let type = "click"
        let t: Double
        let x: CGFloat
        let y: CGFloat
        let button: String
        let down: Bool
        let mods: UInt
    }
}

// MARK: - Reader

/// Parses a .jsonl event log into an in-memory arrays.
enum EventLogReader {
    struct EventLog {
        var clicks: [ClickEvent]
        var cursorSamples: [CursorSample]
    }

    static func read(url: URL) -> EventLog {
        var clicks: [ClickEvent] = []
        var cursorSamples: [CursorSample] = []
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return EventLog(clicks: [], cursorSamples: [])
        }

        for rawLine in text.split(separator: "\n") {
            guard let lineData = rawLine.data(using: .utf8) else { continue }
            guard let probe = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = probe["type"] as? String else { continue }
            let t = (probe["t"] as? Double) ?? 0
            let x = (probe["x"] as? Double) ?? 0
            let y = (probe["y"] as? Double) ?? 0
            let time = CMTime(seconds: t, preferredTimescale: 1_000_000_000)
            let pos = CGPoint(x: x, y: y)

            switch type {
            case "cursor":
                cursorSamples.append(CursorSample(time: time, position: pos))
            case "click":
                let button = ClickEvent.Button(rawValue: (probe["button"] as? String) ?? "left") ?? .left
                let down = (probe["down"] as? Bool) ?? true
                let mods = (probe["mods"] as? UInt) ?? 0
                clicks.append(ClickEvent(time: time, position: pos, button: button, modifiers: mods, isDown: down))
            default: break
            }
        }
        return EventLog(clicks: clicks, cursorSamples: cursorSamples)
    }
}
