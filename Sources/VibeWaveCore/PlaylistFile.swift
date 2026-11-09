import Foundation

public enum PlaylistFileFormat: String, CaseIterable, Codable, Sendable {
    case m3u, m3u8, pls

    public var label: String { rawValue.uppercased() }

    public init?(url: URL) {
        guard url.isFileURL else { return nil }
        self.init(rawValue: url.pathExtension.lowercased())
    }
}

public enum PlaylistFileEncoding: String, CaseIterable, Codable, Sendable {
    case utf8, windows1251, windows1252

    public var label: String {
        switch self {
        case .utf8: return "UTF-8"
        case .windows1251: return "Windows-1251"
        case .windows1252: return "Windows-1252"
        }
    }

    var foundation: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .windows1251: return .windowsCP1251
        case .windows1252: return .windowsCP1252
        }
    }
}

/// Настройки обмена хранятся отдельно от содержимого медиатеки.
public struct PlaylistFileOptions: Codable, Equatable, Sendable {
    public var format: PlaylistFileFormat = .m3u8
    public var exportEncoding: PlaylistFileEncoding = .utf8
    public var legacyImportEncoding: PlaylistFileEncoding = .windows1251
    public var relativePaths = true
    public var reportMissingFiles = true

    public init() {}
}

/// Читает и записывает локальные списки. Разрешение файлов и проверка аудио
/// выполняются при импорте, чтобы различать ошибки формата и отдельных записей.
public enum PlaylistFile {
    public enum Failure: Error, Equatable {
        case invalidFormat, invalidEncoding, streamingManifest, tooLarge, unsupportedPath, lossyEncoding
    }

    public struct Entry: Equatable, Sendable {
        public let path: String
        public let title: String?
    }

    private static let maximumBytes = 8 * 1024 * 1024

    public static func read(_ url: URL, legacyEncoding: PlaylistFileEncoding) throws -> [Entry] {
        guard let format = PlaylistFileFormat(url: url) else { throw Failure.invalidFormat }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data, format: format, legacyEncoding: legacyEncoding)
    }

    public static func decode(_ data: Data, format: PlaylistFileFormat,
                              legacyEncoding: PlaylistFileEncoding) throws -> [Entry] {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let text: String?
        if format != .m3u8, data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
            text = String(data: bytes, encoding: .utf8)
                ?? (format == .m3u8 ? nil : String(data: bytes, encoding: legacyEncoding.foundation))
        }
        guard let text = text, !text.contains("\0") else { throw Failure.invalidEncoding }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if format == .pls { return try decodePLS(lines) }

        var entries: [Entry] = []
        var title: String?
        for line in lines {
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#EXT-X-") { throw Failure.streamingManifest }
            if directive.hasPrefix("#EXTINF:"), let comma = directive.firstIndex(of: ",") {
                title = String(directive[directive.index(after: comma)...])
            } else if !directive.isEmpty && !directive.hasPrefix("#") {
                entries.append(Entry(path: line, title: title))
                title = nil
            }
        }
        return entries
    }

    private static func decodePLS(_ lines: [String]) throws -> [Entry] {
        var paths: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var foundHeader = false
        var inPlaylist = false
        for line in lines {
            let header = line.trimmingCharacters(in: .whitespaces).lowercased()
            if header.hasPrefix("[") {
                inPlaylist = header == "[playlist]"
                foundHeader = foundHeader || inPlaylist
            }
            guard inPlaylist, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: equals)...])
            if key.hasPrefix("file"), let index = Int(key.dropFirst(4)), index > 0, !value.isEmpty {
                paths[index] = value
            } else if key.hasPrefix("title"), let index = Int(key.dropFirst(5)), index > 0 {
                titles[index] = value
            }
        }
        guard foundHeader else { throw Failure.invalidFormat }
        return paths.keys.sorted().compactMap { index in
            paths[index].map { Entry(path: $0, title: titles[index]) }
        }
    }

    /// Обычный путь сначала читается буквально. Если его нет, пробуем обрезать
    /// пробелы вокруг записи и распознать относительные пути с разделителями Windows.
    public static func localURL(for entry: Entry, in playlist: URL) -> URL? {
        let path = entry.path
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "file" {
                guard url.isFileURL, ["", "localhost"].contains(url.host?.lowercased() ?? "") else { return nil }
                return url.standardizedFileURL
            }
            return nil
        }
        guard !trimmed.hasPrefix("\\\\"), !trimmed.hasPrefix("//") else { return nil }

        let folder = playlist.deletingLastPathComponent()
        func resolve(_ value: String) -> URL {
            URL(fileURLWithPath: value, relativeTo: folder).standardizedFileURL
        }
        let literal = resolve(path)
        if FileManager.default.fileExists(atPath: literal.path) { return literal }
        let clean = resolve(trimmed)
        if FileManager.default.fileExists(atPath: clean.path) { return clean }
        return resolve(trimmed.replacingOccurrences(of: "\\", with: "/"))
    }

    /// Путь считается от папки назначения. Префикс ./ отличает имена,
    /// начинающиеся с # или похожие на URL, от служебных строк.
    public static func encode(_ tracks: [Track], destination: URL, options: PlaylistFileOptions) throws -> Data {
        guard let format = PlaylistFileFormat(url: destination) else { throw Failure.invalidFormat }
        var lines = [format == .pls ? "[playlist]" : "#EXTM3U"]
        for (offset, track) in tracks.enumerated() {
            guard track.url.isFileURL else { throw Failure.unsupportedPath }
            let absolute = track.url.standardizedFileURL.path
            let path = options.relativePaths ? relativePath(to: track.url, from: destination.deletingLastPathComponent()) : absolute
            guard !path.contains(where: \.isNewline) else { throw Failure.unsupportedPath }
            let title = track.title.split(whereSeparator: \.isNewline).joined(separator: " ")
            let seconds = Int(exactly: track.duration.rounded(.down)).flatMap { $0 >= 0 ? $0 : nil } ?? -1
            if format == .pls {
                let index = offset + 1
                lines += ["File\(index)=\(path)", "Title\(index)=\(title)", "Length\(index)=\(seconds)"]
            } else {
                lines += ["#EXTINF:\(seconds),\(title)", path]
            }
        }
        if format == .pls { lines += ["NumberOfEntries=\(tracks.count)", "Version=2"] }
        let text = lines.joined(separator: "\n") + "\n"
        let encoding = format == .m3u8 ? String.Encoding.utf8 : options.exportEncoding.foundation
        guard let data = text.data(using: encoding, allowLossyConversion: false),
              String(data: data, encoding: encoding) == text else { throw Failure.lossyEncoding }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        return data
    }

    private static func relativePath(to file: URL, from folder: URL) -> String {
        let base = folder.standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents
        let shared = zip(base, target).prefix(while: { pair in pair.0 == pair.1 }).count
        let pieces = Array(repeating: "..", count: base.count - shared) + target.dropFirst(shared)
        let path = pieces.joined(separator: "/")
        return shared == base.count ? "./" + path : path
    }
}
