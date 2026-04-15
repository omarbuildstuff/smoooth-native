import Foundation

/// List / create / delete recording packages in `~/Movies/Cursorful/Recordings/`.
@MainActor
final class RecordingStore: ObservableObject {

    static let rootURL: URL = {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return base.appendingPathComponent("Cursorful/Recordings", isDirectory: true)
    }()

    init() {
        ensureRoot()
    }

    private func ensureRoot() {
        try? FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
    }

    /// Create a new empty package directory and return its handle.
    func createPackage(id: UUID = UUID()) -> RecordingPackage {
        let url = Self.rootURL.appendingPathComponent("\(id.uuidString).cursorful", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RecordingPackage(url: url)
    }

    /// List all packages, newest first.
    func list() -> [RecordingPackage] {
        ensureRoot()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "cursorful" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return da > db
            }
            .map { RecordingPackage(url: $0) }
    }

    func delete(_ package: RecordingPackage) {
        try? FileManager.default.removeItem(at: package.url)
    }
}
