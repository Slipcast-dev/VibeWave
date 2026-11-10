import Combine
import Foundation

/// Параметры приложения, которые нужны окнам, редактору тегов и службе обновлений.
@MainActor
final class SettingsPreferences: ObservableObject {
    static let shared = SettingsPreferences()
    private let defaults: UserDefaults

    @Published var quitOnClose: Bool {
        didSet { defaults.set(quitOnClose, forKey: "app.quitOnClose") }
    }
    @Published var showArtwork: Bool {
        didSet { defaults.set(showArtwork, forKey: "tags.showArtwork") }
    }
    @Published var confirmTagEdits: Bool {
        didSet { defaults.set(confirmTagEdits, forKey: "tags.confirmEdits") }
    }
    @Published var mediaKeys: Bool {
        didSet { defaults.set(mediaKeys, forKey: "shortcuts.mediaKeys") }
    }
    @Published var automaticUpdates: Bool {
        didSet { defaults.set(automaticUpdates, forKey: "updates.automatic") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quitOnClose = defaults.bool(forKey: "app.quitOnClose")
        showArtwork = defaults.object(forKey: "tags.showArtwork") as? Bool ?? true
        confirmTagEdits = defaults.bool(forKey: "tags.confirmEdits")
        mediaKeys = defaults.object(forKey: "shortcuts.mediaKeys") as? Bool ?? true
        automaticUpdates = defaults.object(forKey: "updates.automatic") as? Bool ?? true
    }
}
