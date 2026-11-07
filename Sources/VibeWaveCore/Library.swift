import Foundation

/// Ссылка на исходный файл: музыка не копируется в библиотеку приложения.
public struct Track: Codable, Identifiable, Equatable {
    public var id: UUID
    public var url: URL
    public var bookmark: Data?
    public var title: String
    public var duration: TimeInterval

    public init(url: URL, duration: TimeInterval, bookmark: Data? = nil) {
        id = UUID()
        self.url = url
        self.bookmark = bookmark
        title = url.deletingPathExtension().lastPathComponent
        self.duration = duration
    }

    public static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["mp3", "flac"].contains(url.pathExtension.lowercased())
    }
}

/// Плейлист хранит порядок треков; удаление записи не удаляет файл с диска.
public struct Playlist: Codable, Identifiable, Equatable {
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

/// Атомарная запись защищает библиотеку от частично сохранённого JSON.
public struct LibraryStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> [Playlist] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Playlist].self, from: Data(contentsOf: url))
    }

    public func save(_ playlists: [Playlist]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(playlists).write(to: url, options: .atomic)
    }
}

public func timeLabel(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let value = Int(min(seconds, Double(Int.max / 2)))
    return String(format: "%d:%02d", value / 60, value % 60)
}


/// nil в playlistID обозначает временную очередь открытых файлов, а не плейлист.
public struct TrackDragPayload: Codable, Equatable {
    public let playlistID: UUID?
    public let trackID: UUID
    public init(playlistID: UUID?, trackID: UUID) {
        self.playlistID = playlistID
        self.trackID = trackID
    }
}

/// Режим меняет только очередь проигрывания, не переставляя записи в библиотеке.
public enum PlaybackOrder: String, CaseIterable {
    case inOrder, shuffled
    public var title: String { self == .inOrder ? "По списку" : "Случайный" }
}

/// Чистые операции над очередью: случайный режим не повторяет треки в одном проходе.
public enum PlaybackQueue {
    public static func make(tracks: [Track], startingAt id: UUID, order: PlaybackOrder) -> [Track] {
        guard order == .shuffled, let current = tracks.first(where: { $0.id == id }) else { return tracks }
        return [current] + tracks.filter { $0.id != id }.shuffled()
    }

    /// Добавление и удаление файлов сохраняют уже выбранную случайную последовательность.
    public static func reconcile(_ queue: [Track], with tracks: [Track], order: PlaybackOrder) -> [Track] {
        guard order == .shuffled else { return tracks }
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = queue.compactMap { byID[$0.id] }
        let included = Set(existing.map(\.id))
        return existing + tracks.filter { !included.contains($0.id) }.shuffled()
    }
}
