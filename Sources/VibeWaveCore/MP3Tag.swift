import Foundation

/// ID3v2.3/2.4 без глобальных флагов. Неизвестные кадры и флаги сохраняются
/// в исходной версии. Нестандартные заголовки отклоняются перед записью.
struct MP3Tag: AudioTagContainer {
    private struct Frame {
        let id: String
        let flags: Int
        let data: Data
    }

    private let version: UInt8
    private let frames: [Frame]
    private let legacy: [AudioTagField: String]
    let audioOffset: UInt64

    init(file: FileHandle) throws {
        let header = try file.readTagBytes(10)
        guard header.prefix(3) == Data("ID3".utf8) else {
            guard header[0] == 0xFF && header[1] & 0xE0 == 0xE0 else {
                throw AudioMetadataFile.Failure.unsupportedLayout
            }
            version = 3
            frames = []
            audioOffset = 0
            legacy = try Self.legacyFields(file)
            return
        }
        let major = header[3]
        guard (major == 3 || major == 4), header[4] == 0, header[5] == 0 else {
            throw AudioMetadataFile.Failure.unsupportedLayout
        }
        version = major
        legacy = [:]
        var tagSize = TagByteReader(Data(header.suffix(4)))
        let length = try tagSize.integer(4, synchsafe: true)
        guard length <= AudioMetadataFile.maximumMetadata else { throw AudioMetadataFile.Failure.tooLarge }
        var reader = TagByteReader(try file.readTagBytes(length))
        var found: [Frame] = []
        while reader.remaining >= 10 && reader.bytes[reader.offset] != 0 {
            let name = try reader.read(4)
            guard name.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
                throw AudioMetadataFile.Failure.damaged
            }
            let size = try reader.integer(4, synchsafe: major == 4)
            let flags = try reader.integer(2)
            let body = try reader.read(size)
            found.append(Frame(id: String(decoding: name, as: UTF8.self), flags: flags, data: body))
        }
        guard reader.bytes.dropFirst(reader.offset).allSatisfy({ $0 == 0 }) else {
            throw AudioMetadataFile.Failure.damaged
        }
        frames = found
        audioOffset = UInt64(10 + length)
    }

    func metadata(includeArtwork: Bool) -> AudioMetadata {
        var result = AudioMetadata()
        result.fields = legacy
        var isFront = false
        for frame in frames where frame.flags & 0xFF == 0 {
            if let field = Self.field(frame.id), result.fields[field] == nil {
                if field == .comment {
                    if let value = Self.comment(frame.data), value.description.isEmpty { result.fields[field] = value.text }
                } else if let encoding = frame.data.first {
                    result.fields[field] = Self.decode(Data(frame.data.dropFirst()), encoding: encoding)
                }
            }
            if includeArtwork && !isFront && frame.id == "APIC", let picture = Self.picture(frame.data) {
                if picture.type == 3 || result.artwork == nil { result.artwork = picture.artwork }
                isFront = picture.type == 3
            }
        }
        return result
    }

    func applying(_ edit: AudioTagEdit) throws -> Data {
        var updated: [Frame] = []
        for frame in frames {
            if let field = Self.field(frame.id), edit.fields[field] != nil {
                // Сохраняем дополнительные именованные комментарии.
                if field != .comment { continue }
                guard frame.flags & 0xFF == 0, let comment = Self.comment(frame.data) else {
                    throw AudioMetadataFile.Failure.unsupportedLayout
                }
                if comment.description.isEmpty { continue }
            }
            if edit.changesArtwork && frame.id == "APIC" {
                if case .remove = edit.artwork { continue }
                guard frame.flags & 0xFF == 0, let type = Self.pictureType(frame.data) else {
                    throw AudioMetadataFile.Failure.unsupportedLayout
                }
                if type == 3 { continue }
            }
            updated.append(frame)
        }

        for field in AudioTagField.allCases {
            guard let value = edit.fields[field] ?? legacy[field], !value.isEmpty else { continue }
            var payload = Data([1]) // UTF-16 с BOM подходит и для ID3v2.3, и для v2.4.
            if field == .comment { payload.append(contentsOf: [0x65, 0x6E, 0x67, 0xFF, 0xFE, 0, 0]) }
            payload.append(value.data(using: .utf16) ?? Data())
            updated.append(Frame(id: frameID(for: field), flags: 0, data: payload))
        }
        if case .replace(let artwork) = edit.artwork {
            var payload = Data([0])
            payload.append(contentsOf: artwork.mime.utf8)
            payload.append(contentsOf: [0, 3, 0])
            payload.append(artwork.data)
            updated.append(Frame(id: "APIC", flags: 0, data: payload))
        }

        var body = Data()
        for frame in updated {
            body.append(contentsOf: frame.id.utf8)
            body.appendTagInteger(frame.data.count, bytes: 4, synchsafe: version == 4)
            body.appendTagInteger(frame.flags, bytes: 2)
            body.append(frame.data)
        }
        guard body.count <= AudioMetadataFile.maximumMetadata else { throw AudioMetadataFile.Failure.tooLarge }
        var header = Data("ID3".utf8)
        header.append(contentsOf: [version, 0, 0])
        header.appendTagInteger(body.count, bytes: 4, synchsafe: true)
        header.append(body)
        return header
    }

    private static func field(_ id: String) -> AudioTagField? {
        switch id {
        case "TIT2": return .title
        case "TPE1": return .artist
        case "TPE2": return .albumArtist
        case "TALB": return .album
        case "TCON": return .genre
        case "TDRC", "TYER": return .year
        case "TRCK": return .track
        case "TPOS": return .disc
        case "COMM": return .comment
        default: return nil
        }
    }

    private func frameID(for field: AudioTagField) -> String {
        switch field {
        case .title: return "TIT2"
        case .artist: return "TPE1"
        case .albumArtist: return "TPE2"
        case .album: return "TALB"
        case .genre: return "TCON"
        case .year: return version == 4 ? "TDRC" : "TYER"
        case .track: return "TRCK"
        case .disc: return "TPOS"
        case .comment: return "COMM"
        }
    }

    private static func decode(_ data: Data, encoding: UInt8) -> String? {
        let format: String.Encoding
        switch encoding {
        case 0: format = .isoLatin1
        case 1: format = .utf16
        case 2: format = .utf16BigEndian
        case 3: format = .utf8
        default: return nil
        }
        return String(data: data, encoding: format)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static func terminator(in data: Data, from start: Int, encoding: UInt8) -> (Int, Int)? {
        let width = (encoding == 1 || encoding == 2) ? 2 : 1
        guard start <= data.count - width else { return nil }
        for index in stride(from: start, through: data.count - width, by: width) {
            if data[index] == 0 && (width == 1 || data[index + 1] == 0) { return (index, index + width) }
        }
        return nil
    }

    private static func comment(_ data: Data) -> (description: String, text: String)? {
        guard let encoding = data.first, let (end, start) = terminator(in: data, from: 4, encoding: encoding),
              let text = decode(Data(data[start...]), encoding: encoding) else { return nil }
        let description = decode(Data(data[4..<end]), encoding: encoding) ?? ""
        return (description, text)
    }

    private static func pictureType(_ data: Data) -> UInt8? {
        guard let (_, type) = terminator(in: data, from: 1, encoding: 0), type < data.count else { return nil }
        return data[type]
    }

    private static func picture(_ data: Data) -> (type: UInt8, artwork: AudioArtwork)? {
        guard let encoding = data.first, let (mimeEnd, type) = terminator(in: data, from: 1, encoding: 0),
              type < data.count, let (_, start) = terminator(in: data, from: type + 1, encoding: encoding),
              data.count - start <= AudioArtwork.maximumSize else { return nil }
        let mime = String(decoding: data[1..<mimeEnd], as: UTF8.self)
        guard mime != "-->" else { return nil }
        return (data[type], AudioArtwork(data: Data(data[start...]), mime: mime))
    }

    private static func legacyFields(_ file: FileHandle) throws -> [AudioTagField: String] {
        let length = try file.seekToEnd()
        guard length >= 128 else { return [:] }
        try file.seek(toOffset: length - 128)
        let tag = try file.readTagBytes(128)
        guard tag.prefix(3) == Data("TAG".utf8) else { return [:] }
        let ranges: [(AudioTagField, Range<Int>)] = [
            (.title, 3..<33), (.artist, 33..<63), (.album, 63..<93), (.year, 93..<97),
            (.comment, 97..<(tag[125] == 0 && tag[126] != 0 ? 125 : 127))
        ]
        var result: [AudioTagField: String] = [:]
        for (field, range) in ranges {
            if let value = decode(Data(tag[range]), encoding: 0)?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                result[field] = value
            }
        }
        if tag[125] == 0 && tag[126] != 0 { result[.track] = String(tag[126]) }
        return result
    }
}
