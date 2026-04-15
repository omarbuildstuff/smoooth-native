import Foundation

/// A `.cursorful` package on disk. It's a plain directory (not a document bundle) containing:
///   video.mov     - HEVC screen capture (raw, no effects baked)
///   webcam.mov    - optional Phase 2 webcam capture
///   audio.m4a     - optional, may be nil if audio is embedded in video.mov
///   events.jsonl  - one JSON object per line: click events + cursor samples
///   meta.json     - RecordingSessionMeta
///   project.json  - Timeline `Project` (non-destructive edit state)
struct RecordingPackage: Hashable, Identifiable {
    let url: URL
    let id: UUID

    init(url: URL) {
        self.url = url
        // Stable UUID from the folder name (which is a UUID) or a new one if parse fails.
        let name = url.deletingPathExtension().lastPathComponent
        self.id = UUID(uuidString: name) ?? UUID()
    }

    var videoURL: URL    { url.appendingPathComponent("video.mov") }
    var webcamURL: URL   { url.appendingPathComponent("webcam.mov") }
    var audioURL: URL    { url.appendingPathComponent("audio.m4a") }
    var eventsURL: URL   { url.appendingPathComponent("events.jsonl") }
    var metaURL: URL     { url.appendingPathComponent("meta.json") }
    var projectURL: URL  { url.appendingPathComponent("project.json") }

    func hasVideo() -> Bool { FileManager.default.fileExists(atPath: videoURL.path) }
    func hasEvents() -> Bool { FileManager.default.fileExists(atPath: eventsURL.path) }

    func loadMeta() -> RecordingSessionMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(RecordingSessionMeta.self, from: data)
    }

    func writeMeta(_ meta: RecordingSessionMeta) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: metaURL, options: .atomic)
    }
}
