import Foundation

public enum AudioTagField: String, CaseIterable, Identifiable, Sendable {
    case title, artist, albumArtist, album, genre, year, track, disc, comment

    public var id: Self { self }
}

public struct AudioArtwork: Equatable, Sendable {
    public static let maximumSize = 12 * 1024 * 1024
    public let data: Data
    public let mime: String
    public let width: UInt32
    public let height: UInt32

    public init(data: Data, mime: String, width: UInt32 = 0, height: UInt32 = 0) {
        self.data = data
        self.mime = mime
        self.width = width
        self.height = height
    }
}

public struct AudioMetadata: Sendable {
    public var fields: [AudioTagField: String] = [:]
    public var artwork: AudioArtwork?
    public var replayGain = ReplayGainValues()
    public init() {}
}

public struct AudioTagEdit: Sendable {
    public enum ArtworkChange: Sendable { case unchanged, remove, replace(AudioArtwork) }
    public var fields: [AudioTagField: String] = [:]
    public var artwork: ArtworkChange = .unchanged
    /// nil сохраняет теги, структура заменяет все четыре поля, nil внутри неё удаляет поле.
    public var replayGain: ReplayGainValues?

    public init() {}

    public var changesArtwork: Bool {
        if case .unchanged = artwork { return false }
        return true
    }

    public var isEmpty: Bool { fields.isEmpty && !changesArtwork && replayGain == nil }
}

/// Работа с ограниченным объёмом метаданных. При записи аудиопоток
/// копируется блоками в новый файл на том же томе, затем файл заменяется целиком.
public enum AudioMetadataFile {
    public enum Failure: Error {
        case unsupportedLayout, damaged, tooLarge, changedDuringWrite, readOnly
        case invalidField(AudioTagField), invalidReplayGain
    }

    static let maximumMetadata = 32 * 1024 * 1024

    public static func read(_ url: URL, includeArtwork: Bool = true) throws -> AudioMetadata {
        guard let format = AudioFormat(url: url), format.readsTags,
              MusicFiles.isRegularFile(url) else { throw Failure.unsupportedLayout }
        if format == .mpeg4 { return try MPEG4Metadata.read(url, includeArtwork: includeArtwork) }
        if format == .ogg { return try OggTag.read(url, includeArtwork: includeArtwork) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try readContainer(url, file).metadata(includeArtwork: includeArtwork)
    }

    public static func write(_ edit: AudioTagEdit, to fileURL: URL) throws -> AudioMetadata {
        guard !edit.isEmpty else { return try read(fileURL) }
        guard AudioFormat(url: fileURL)?.writesTags == true else { throw Failure.unsupportedLayout }
        guard edit.replayGain?.isValid != false else { throw Failure.invalidReplayGain }
        for (field, value) in edit.fields {
            guard !value.contains("\0"), value.utf8.count <= 65_536 else { throw Failure.invalidField(field) }
            if value.isEmpty { continue }
            if field == .year, (value.utf8.count != 4 || Int(value).map({ (1...9999).contains($0) }) != true) {
                throw Failure.invalidField(field)
            }
            if field == .track || field == .disc {
                let numbers = value.split(separator: "/", omittingEmptySubsequences: false)
                guard (1...2).contains(numbers.count), numbers.allSatisfy({ Int($0).map { $0 > 0 } == true }) else {
                    throw Failure.invalidField(field)
                }
            }
        }
        let url = fileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey,
                                         .isRegularFileKey, .isWritableKey]
        let before = try url.resourceValues(forKeys: keys)
        func linkCount() throws -> Int {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            return (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1
        }
        let links = try linkCount()
        // Замена жёсткой ссылки разошлась бы с другими именами того же файла.
        guard before.isRegularFile == true, before.isWritable == true, links == 1 else {
            throw Failure.readOnly
        }
        if case .replace(let artwork) = edit.artwork,
           artwork.data.isEmpty || artwork.data.count > AudioArtwork.maximumSize ||
           !["image/jpeg", "image/png"].contains(artwork.mime) { throw Failure.tooLarge }

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let container = try readContainer(url, input)
        guard try input.seekToEnd() > container.audioOffset else { throw Failure.damaged }
        let prefix = try container.applying(edit)
        guard prefix.count <= maximumMetadata else { throw Failure.tooLarge }

        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: url, create: true)
        defer { try? manager.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(url.lastPathComponent)
        try prefix.write(to: temporary)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.seekToEnd()
        try input.seek(toOffset: container.audioOffset)
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
        // Перечитываем копию до замены, чтобы проверить структуру и получить сохранённые значения.
        let result = try read(temporary, includeArtwork: false)
        let freshURL = URL(fileURLWithPath: url.path)
        let after = try freshURL.resourceValues(forKeys: keys)
        let currentLinks = try linkCount()
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
              (before.fileResourceIdentifier as? NSObject) == (after.fileResourceIdentifier as? NSObject),
              after.isWritable == true, currentLinks == 1 else { throw Failure.changedDuringWrite }
        _ = try manager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil)
        return result
    }

    private static func readContainer(_ url: URL, _ file: FileHandle) throws -> AudioTagContainer {
        switch AudioFormat(url: url) {
        case .mp3: return try MP3Tag(file: file)
        case .flac: return try FLACTag(file: file)
        default: throw Failure.unsupportedLayout
        }
    }
}

protocol AudioTagContainer {
    var audioOffset: UInt64 { get }
    func metadata(includeArtwork: Bool) -> AudioMetadata
    func applying(_ edit: AudioTagEdit) throws -> Data
}

extension FileHandle {
    /// Читаем точное количество байтов, отличая обрезанный заголовок от пустых полей.
    func readTagBytes(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count, let chunk = try read(upToCount: count - result.count), !chunk.isEmpty {
            result.append(chunk)
        }
        guard result.count == count else { throw AudioMetadataFile.Failure.damaged }
        return result
    }
}

struct TagByteReader {
    let bytes: Data
    private(set) var offset = 0
    var remaining: Int { bytes.count - offset }

    init(_ bytes: Data) { self.bytes = bytes }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw AudioMetadataFile.Failure.damaged }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func lengthPrefixed(littleEndian: Bool = false) throws -> Data {
        let length = try integer(4, littleEndian: littleEndian)
        return try read(length)
    }

    mutating func integer(_ count: Int, littleEndian: Bool = false, synchsafe: Bool = false) throws -> Int {
        let data = try read(count)
        if synchsafe && data.contains(where: { $0 >= 128 }) { throw AudioMetadataFile.Failure.damaged }
        let ordered = littleEndian ? Array(data.reversed()) : Array(data)
        return ordered.reduce(0) { ($0 << (synchsafe ? 7 : 8)) | Int($1) }
    }
}

extension Data {
    mutating func appendTagInteger(_ value: Int, bytes: Int, littleEndian: Bool = false, synchsafe: Bool = false) {
        let width = synchsafe ? 7 : 8
        for index in 0..<bytes {
            let shift = (littleEndian ? index : bytes - 1 - index) * width
            append(UInt8((value >> shift) & (synchsafe ? 127 : 255)))
        }
    }
}
