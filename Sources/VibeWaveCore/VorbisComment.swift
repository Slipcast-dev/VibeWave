import Foundation

/// Vorbis Comment (FLAC, Ogg Vorbis, OpusTags): длина и строки в little-endian,
/// поля «КЛЮЧ=значение» в UTF-8. Неизвестные поля сохраняются при перезаписи.
struct VorbisComment {
    let vendor: Data
    let values: [Data]

    init(_ data: Data) throws {
        var reader = TagByteReader(data)
        vendor = try reader.lengthPrefixed(littleEndian: true)
        let count = try reader.integer(4, littleEndian: true)
        guard count <= reader.remaining / 4 else { throw AudioMetadataFile.Failure.damaged }
        var result: [Data] = []
        for _ in 0..<count { result.append(try reader.lengthPrefixed(littleEndian: true)) }
        guard reader.remaining == 0 else { throw AudioMetadataFile.Failure.damaged }
        values = result
    }

    init(vendor: Data, values: [Data]) {
        self.vendor = vendor
        self.values = values
    }

    init() {
        vendor = Data("VibeWave".utf8)
        values = []
    }

    func updated(_ edits: [AudioTagField: String], replayGain: ReplayGainValues?) -> Data {
        var result = values.filter { value in
            guard let key = Self.split(value)?.0 else { return true }
            if replayGain != nil && ReplayGainValues.Tag(rawValue: key) != nil { return false }
            guard let field = Self.field(for: key) else { return true }
            return edits[field] == nil
        }
        for field in AudioTagField.allCases {
            if let value = edits[field], !value.isEmpty {
                result.append(Data("\(Self.key(for: field))=\(value)".utf8))
            }
        }
        if let replayGain = replayGain {
            for tag in ReplayGainValues.Tag.allCases {
                if let value = replayGain.tagValue(tag) {
                    result.append(Data("\(tag.rawValue)=\(value)".utf8))
                }
            }
        }
        var data = Data()
        data.appendTagInteger(vendor.count, bytes: 4, littleEndian: true)
        data.append(vendor)
        data.appendTagInteger(result.count, bytes: 4, littleEndian: true)
        for value in result {
            data.appendTagInteger(value.count, bytes: 4, littleEndian: true)
            data.append(value)
        }
        return data
    }

    static func split(_ value: Data) -> (String, String)? {
        guard let text = String(data: value, encoding: .utf8), let equal = text.firstIndex(of: "=") else { return nil }
        return (String(text[..<equal]).uppercased(), String(text[text.index(after: equal)...]))
    }

    static func field(for key: String) -> AudioTagField? {
        if key == "DESCRIPTION" { return .comment }
        if key == "YEAR" { return .year }
        return AudioTagField.allCases.first { Self.key(for: $0) == key }
    }

    static func key(for field: AudioTagField) -> String {
        switch field {
        case .year: return "DATE"
        case .track: return "TRACKNUMBER"
        case .disc: return "DISCNUMBER"
        default: return field.rawValue.uppercased()
        }
    }
}
