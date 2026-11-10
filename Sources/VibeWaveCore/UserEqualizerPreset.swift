import Foundation

public enum UserEqualizerPresetError: Error, Equatable {
    case invalidName, duplicateName, invalidValues, invalidFile, unsupportedVersion, fileTooLarge
    case libraryFull, invalidLibrary
}

/// Сохраняются предусиление и значения полос. Применение пресета включает EQ,
/// как и выбор встроенного пресета.
public struct UserEqualizerPreset: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameLength = 64
    public static let maximumNameBytes = 512

    public let id: UUID
    public let name: String
    public let preamp: Float
    public let gains: [Float]

    public init(id: UUID = UUID(), name: String, preamp: Float, gains: [Float]) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maximumNameLength, name.utf8.count <= Self.maximumNameBytes,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw UserEqualizerPresetError.invalidName
        }
        let range = EqualizerSettings.gainRange
        guard gains.count == EqualizerSettings.frequencies.count,
              range.contains(preamp), gains.allSatisfy(range.contains) else {
            throw UserEqualizerPresetError.invalidValues
        }
        self.id = id
        self.name = name
        self.preamp = preamp
        self.gains = gains
    }

    public init(name: String, settings: EqualizerSettings) throws {
        try self.init(name: name, preamp: settings.preamp, gains: settings.gains)
    }

    public func renamed(_ name: String) throws -> Self {
        try Self(id: id, name: name, preamp: preamp, gains: gains)
    }

    public var settings: EqualizerSettings {
        EqualizerSettings(enabled: true, preamp: preamp, gains: gains)
    }

    public var nameKey: String {
        name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private enum CodingKeys: String, CodingKey { case id, name, preamp, gains }

    /// Импорт не пропускает повреждённые значения через корректирующий
    /// инициализатор EqualizerSettings.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      preamp: values.decode(Float.self, forKey: .preamp),
                      gains: values.decode([Float].self, forKey: .gains))
    }
}

/// Версионированный файл для обмена отдельным пользовательским пресетом.
public enum EqualizerPresetFile {
    public static let maximumSize = 32 * 1024

    public static func encode(_ preset: UserEqualizerPreset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(version: 1, preset: preset))
    }

    public static func decode(_ data: Data) throws -> UserEqualizerPreset {
        guard data.count <= maximumSize else { throw UserEqualizerPresetError.fileTooLarge }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == 1 else { throw UserEqualizerPresetError.unsupportedVersion }
            return try decoder.decode(Document.self, from: data).preset
        } catch let error as UserEqualizerPresetError {
            throw error
        } catch {
            throw UserEqualizerPresetError.invalidFile
        }
    }

    private struct Header: Decodable { let version: Int }

    private struct Document: Codable {
        let version: Int
        let preset: UserEqualizerPreset
    }
}
