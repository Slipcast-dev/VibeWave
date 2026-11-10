import Foundation

/// Ссылка на исходный файл: музыка не копируется в библиотеку приложения.
public struct Track: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var bookmark: Data?
    public var title: String
    public var duration: TimeInterval
    public var addedAt: Date?

    public init(url: URL, duration: TimeInterval, bookmark: Data? = nil, addedAt: Date? = Date()) {
        id = UUID()
        self.url = url
        self.bookmark = bookmark
        title = url.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.addedAt = addedAt
    }

    public static func accepts(_ url: URL) -> Bool {
        AudioFormat(url: url) != nil
    }
}

/// Плейлист хранит порядок треков; удаление записи не удаляет файл с диска.
public struct Playlist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var tracks: [Track]

    public init(name: String, tracks: [Track] = []) {
        id = UUID()
        self.name = name
        self.tracks = tracks
    }

    public mutating func append(_ track: Track) {
        guard !tracks.contains(where: { $0.url.standardizedFileURL == track.url.standardizedFileURL }) else { return }
        tracks.append(track)
    }

    /// Переносит запись перед указанным треком; nil означает конец списка.
    /// Неизвестные идентификаторы и перенос на себя ничего не меняют.
    @discardableResult
    public mutating func moveTrack(_ id: UUID, before destination: UUID?) -> Bool {
        guard id != destination,
              let source = tracks.firstIndex(where: { $0.id == id }),
              destination == nil || tracks.contains(where: { $0.id == destination }) else { return false }
        let track = tracks.remove(at: source)
        let target = destination.flatMap { value in tracks.firstIndex { $0.id == value } } ?? tracks.endIndex
        tracks.insert(track, at: target)
        return true
    }

}

/// Папка с музыкой на диске: список треков пересканируется по команде пользователя.
public struct MusicFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var bookmark: Data?
    public var name: String
    public var tracks: [Track]

    public init(url: URL, bookmark: Data? = nil, tracks: [Track] = []) {
        id = UUID()
        self.url = url
        self.bookmark = bookmark
        name = url.lastPathComponent
        self.tracks = tracks
    }

    /// Пересканирование сохраняет ID и порядок известных файлов, новые добавляются в конец.
    public mutating func merge(scanned: [Track]) {
        merge(files: scanned.map(\.url), added: scanned)
    }

    /// files — все файлы, найденные в папке; added — прочитанные треки для новых файлов.
    /// Известные файлы не нужно открывать повторно: их записи остаются как есть,
    /// исчезнувшие с диска убираются, новые добавляются в конец в порядке files.
    public mutating func merge(files: [URL], added: [Track]) {
        let present = Set(files.map(\.standardizedFileURL))
        let kept = tracks.filter { present.contains($0.url.standardizedFileURL) }
        var seen = Set(kept.map { $0.url.standardizedFileURL })
        tracks = kept + added.filter { present.contains($0.url.standardizedFileURL) && seen.insert($0.url.standardizedFileURL).inserted }
    }
}

/// Всё, что хранится на диске: плейлисты, папки и ручной порядок раздела «Вся музыка».
public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var playlists: [Playlist]
    public var folders: [MusicFolder]
    public var order: [UUID]
    public var smartPlaylists: [SmartPlaylist]

    public init(playlists: [Playlist] = [], folders: [MusicFolder] = [], order: [UUID] = [],
                smartPlaylists: [SmartPlaylist] = []) {
        self.playlists = playlists
        self.folders = folders
        self.order = order
        self.smartPlaylists = smartPlaylists
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlists = try container.decode([Playlist].self, forKey: .playlists)
        folders = try container.decodeIfPresent([MusicFolder].self, forKey: .folders) ?? []
        order = try container.decodeIfPresent([UUID].self, forKey: .order) ?? []
        smartPlaylists = try container.decodeIfPresent([SmartPlaylist].self, forKey: .smartPlaylists) ?? []
    }
}

/// Атомарная запись защищает библиотеку от частично сохранённого JSON.
/// Старый формат (массив плейлистов) читается без изменений файла.
public struct LibraryStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func loadSnapshot() throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibrarySnapshot() }
        let data = try Data(contentsOf: url)
        if let legacy = try? JSONDecoder().decode([Playlist].self, from: data) {
            return LibrarySnapshot(playlists: legacy)
        }
        return try JSONDecoder().decode(LibrarySnapshot.self, from: data)
    }

    public func load() throws -> [Playlist] { try loadSnapshot().playlists }

    public func save(_ snapshot: LibrarySnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public func save(_ playlists: [Playlist]) throws {
        try save(LibrarySnapshot(playlists: playlists))
    }
}

/// Ручной порядок общего списка: известные ID идут по порядку, новые — в конце.
public enum ManualOrder {
    public static func arrange<T>(_ items: [T], order: [UUID], id: (T) -> UUID) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = items.filter { rank[id($0)] != nil }.sorted { rank[id($0)]! < rank[id($1)]! }
        return ranked + items.filter { rank[id($0)] == nil }
    }

    /// Возвращает новый порядок или nil, если перенос невозможен.
    public static func move(_ item: UUID, before destination: UUID?, in ids: [UUID]) -> [UUID]? {
        guard item != destination, ids.contains(item),
              destination == nil || ids.contains(destination!) else { return nil }
        var result = ids.filter { $0 != item }
        let index = destination.flatMap { value in result.firstIndex(of: value) } ?? result.endIndex
        result.insert(item, at: index)
        return result
    }
}

public func timeLabel(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let value = Int(min(seconds, Double(Int.max / 2)))
    return String(format: "%d:%02d", value / 60, value % 60)
}


/// playlistID — ID источника (плейлист или папка); nil — музыка вне плейлистов.
public struct TrackDragPayload: Codable, Equatable, Sendable {
    public let playlistID: UUID?
    public let trackID: UUID
    public init(playlistID: UUID?, trackID: UUID) {
        self.playlistID = playlistID
        self.trackID = trackID
    }
}


