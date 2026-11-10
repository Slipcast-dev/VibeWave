import Combine
import Foundation
import VibeWaveCore

/// Локальная коллекция хранится одним JSON-значением. При неудачной загрузке
/// исходное значение остаётся на месте и библиотека не перезаписывается.
@MainActor
final class EqualizerPresetLibrary: ObservableObject {
    static let defaultsKey = "audio.equalizer.userPresets"
    private static let maximumPresets = 128
    private static let maximumLibrarySize = 512 * 1024

    @Published private(set) var presets: [UserEqualizerPreset] = []
    private(set) var loadFailed = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.defaultsKey) else { return }
        guard let data = stored as? Data, data.count <= Self.maximumLibrarySize,
              let saved = try? JSONDecoder().decode([UserEqualizerPreset].self, from: data),
              saved.count <= Self.maximumPresets,
              Set(saved.map(\.id)).count == saved.count,
              Set(saved.map(\.nameKey)).count == saved.count else {
            loadFailed = true
            return
        }
        presets = saved
    }

    @discardableResult
    func add(name: String, settings: EqualizerSettings) throws -> UserEqualizerPreset {
        try insert(UserEqualizerPreset(name: name, settings: settings))
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let renamed = try presets[index].renamed(name)
        guard !presets.contains(where: { $0.id != id && $0.nameKey == renamed.nameKey }) else {
            throw UserEqualizerPresetError.duplicateName
        }
        var updated = presets
        updated[index] = renamed
        try save(updated)
    }

    func remove(_ id: UUID) throws {
        let updated = presets.filter { $0.id != id }
        if updated.count != presets.count { try save(updated) }
    }

    /// Импорт всегда создаёт отдельную запись. При совпадении имени
    /// добавляется свободный номер без изменения существующих пресетов.
    @discardableResult
    func addImported(_ preset: UserEqualizerPreset) throws -> UserEqualizerPreset {
        let usedNames = Set(presets.map(\.nameKey))
        var imported = try UserEqualizerPreset(name: preset.name, settings: preset.settings)
        var number = 2
        while usedNames.contains(imported.nameKey) {
            let suffix = " (\(number))"
            var prefix = preset.name.prefix(UserEqualizerPreset.maximumNameLength - suffix.count)
            while prefix.utf8.count + suffix.utf8.count > UserEqualizerPreset.maximumNameBytes {
                prefix = prefix.dropLast()
            }
            let baseName = prefix.isEmpty ? "EQ" : String(prefix)
            imported = try imported.renamed(baseName + suffix)
            number += 1
        }
        return try insert(imported)
    }

    private func insert(_ preset: UserEqualizerPreset) throws -> UserEqualizerPreset {
        guard presets.count < Self.maximumPresets else { throw UserEqualizerPresetError.libraryFull }
        guard !presets.contains(where: { $0.nameKey == preset.nameKey }) else {
            throw UserEqualizerPresetError.duplicateName
        }
        try save(presets + [preset])
        return preset
    }

    private func save(_ updated: [UserEqualizerPreset]) throws {
        guard !loadFailed else { throw UserEqualizerPresetError.invalidLibrary }
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.defaultsKey)
        presets = updated
    }
}
