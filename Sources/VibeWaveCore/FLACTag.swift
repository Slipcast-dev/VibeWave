import Foundation

/// Читаем Vorbis Comment и встроенные PICTURE. Неизвестные блоки и
/// невыбранные комментарии переписываются байт в байт.
struct FLACTag: AudioTagContainer {
    private struct Block {
        let kind: UInt8
        let data: Data
    }

    private struct Comment {
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

        init() {
            vendor = Data("VibeWave".utf8)
            values = []
        }

        func updated(_ edits: [AudioTagField: String], replayGain: ReplayGainValues?) -> Data {
            var result = values.filter { value in
                guard let key = Self.split(value)?.0 else { return true }
                if replayGain != nil && ReplayGainValues.Tag(rawValue: key) != nil { return false }
                guard let field = FLACTag.field(for: key) else { return true }
                return edits[field] == nil
            }
            for field in AudioTagField.allCases {
                if let value = edits[field], !value.isEmpty {
                    result.append(Data("\(FLACTag.key(for: field))=\(value)".utf8))
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
    }

    private let blocks: [Block]
    private let comment: Comment?
    let audioOffset: UInt64

    init(file: FileHandle) throws {
        guard try file.readTagBytes(4) == Data("fLaC".utf8) else { throw AudioMetadataFile.Failure.unsupportedLayout }
        var result: [Block] = []
        var last = false
        var bytes = 4
        while !last {
            var header = TagByteReader(try file.readTagBytes(4))
            let flags = try header.integer(1)
            let length = try header.integer(3)
            last = flags & 0x80 != 0
            let kind = UInt8(flags & 0x7F)
            bytes += length + 4
            guard bytes <= AudioMetadataFile.maximumMetadata, result.count < 4096 else { throw AudioMetadataFile.Failure.tooLarge }
            guard kind != 127, result.isEmpty ? kind == 0 && length == 34 : kind != 0 else {
                throw AudioMetadataFile.Failure.damaged
            }
            result.append(Block(kind: kind, data: try file.readTagBytes(length)))
        }
        let comments = result.filter { $0.kind == 4 }
        guard comments.count <= 1 else { throw AudioMetadataFile.Failure.damaged }
        blocks = result
        comment = try comments.first.map { try Comment($0.data) }
        audioOffset = UInt64(bytes)
    }

    func metadata(includeArtwork: Bool) -> AudioMetadata {
        var result = AudioMetadata()
        for value in comment?.values ?? [] {
            guard let (key, text) = Comment.split(value) else { continue }
            if let field = Self.field(for: key), result.fields[field] == nil { result.fields[field] = text }
            result.replayGain.readTag(key, value: text)
        }
        if includeArtwork {
            for block in blocks where block.kind == 6 {
                guard let picture = try? Self.picture(block.data) else { continue }
                if picture.0 == 3 || result.artwork == nil { result.artwork = picture.1 }
                if picture.0 == 3 { break }
            }
        }
        return result
    }

    func applying(_ edit: AudioTagEdit) throws -> Data {
        var result = blocks
        if !edit.fields.isEmpty || edit.replayGain != nil {
            let block = Block(kind: 4, data: (comment ?? Comment()).updated(edit.fields, replayGain: edit.replayGain))
            if let index = result.firstIndex(where: { $0.kind == 4 }) { result[index] = block }
            else { result.append(block) }
        }
        if edit.changesArtwork {
            result = try result.filter { block in
                guard block.kind == 6 else { return true }
                if case .remove = edit.artwork { return false }
                var reader = TagByteReader(block.data)
                return try reader.integer(4) != 3
            }
            if case .replace(let artwork) = edit.artwork {
                var picture = Data()
                picture.appendTagInteger(3, bytes: 4)
                picture.appendTagInteger(artwork.mime.utf8.count, bytes: 4)
                picture.append(contentsOf: artwork.mime.utf8)
                picture.appendTagInteger(0, bytes: 4)
                picture.appendTagInteger(Int(artwork.width), bytes: 4)
                picture.appendTagInteger(Int(artwork.height), bytes: 4)
                picture.appendTagInteger(0, bytes: 4) // Глубина цвета неизвестна.
                picture.appendTagInteger(0, bytes: 4)
                picture.appendTagInteger(artwork.data.count, bytes: 4)
                picture.append(artwork.data)
                result.append(Block(kind: 6, data: picture))
            }
        }
        var prefix = Data("fLaC".utf8)
        for (index, block) in result.enumerated() {
            guard block.data.count <= 0xFF_FFFF else { throw AudioMetadataFile.Failure.tooLarge }
            prefix.append(block.kind | (index == result.count - 1 ? 0x80 : 0))
            prefix.appendTagInteger(block.data.count, bytes: 3)
            prefix.append(block.data)
        }
        return prefix
    }

    private static func picture(_ data: Data) throws -> (Int, AudioArtwork) {
        var reader = TagByteReader(data)
        let type = try reader.integer(4)
        let mime = String(decoding: try reader.lengthPrefixed(), as: UTF8.self)
        _ = try reader.lengthPrefixed()
        let width = UInt32(try reader.integer(4))
        let height = UInt32(try reader.integer(4))
        _ = try reader.read(8)
        let size = try reader.integer(4)
        guard mime != "-->", size <= AudioArtwork.maximumSize else { throw AudioMetadataFile.Failure.tooLarge }
        return (type, AudioArtwork(data: try reader.read(size), mime: mime, width: width, height: height))
    }

    private static func field(for key: String) -> AudioTagField? {
        if key == "DESCRIPTION" { return .comment }
        if key == "YEAR" { return .year }
        return AudioTagField.allCases.first { Self.key(for: $0) == key }
    }

    private static func key(for field: AudioTagField) -> String {
        switch field {
        case .year: return "DATE"
        case .track: return "TRACKNUMBER"
        case .disc: return "DISCNUMBER"
        default: return field.rawValue.uppercased()
        }
    }
}
