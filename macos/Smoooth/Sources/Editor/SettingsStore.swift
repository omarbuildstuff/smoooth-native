import Foundation
import SmooothCore

/// Persists user settings (UserDefaults) and presets (JSON in Application Support),
/// mirroring the original electron-store keys.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private let cursorScaleKey = "recorder.cursorScale"
    private let modeKey = "ui.mode"

    var cursorScale: Int {
        get { defaults.object(forKey: cursorScaleKey) as? Int ?? Defaults.Cursor.scaleDefault }
        set { defaults.set(newValue, forKey: cursorScaleKey) }
    }

    /// "light" or "dark"
    var mode: String {
        get { defaults.string(forKey: modeKey) ?? "dark" }
        set { defaults.set(newValue, forKey: modeKey) }
    }

    var lastActivePresetID: String? {
        get { defaults.string(forKey: Defaults.lastPresetIdKey) }
        set { defaults.set(newValue, forKey: Defaults.lastPresetIdKey) }
    }

    private var presetsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Smoooth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    func loadPresets() -> [String: Preset] {
        guard let data = try? Data(contentsOf: presetsURL),
              let presets = try? JSONDecoder().decode([String: Preset].self, from: data) else {
            return [:]
        }
        return presets
    }

    func savePresets(_ presets: [String: Preset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: presetsURL)
    }
}
