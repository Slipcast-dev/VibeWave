import Foundation

public struct ListeningEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let date: Date
}

public struct ListeningSummary: Codable, Equatable, Sendable {
    public var count: Int
    public var lastPlayed: Date
}

/// Оценки и статистика относятся к локальному файлу, а не к строке плейлиста.
public struct ListeningActivity: Codable, Equatable, Sendable {
    public private(set) var ratings: [String: Int] = [:]
    public private(set) var summaries: [String: ListeningSummary] = [:]
    public private(set) var events: [ListeningEvent] = []

    public init() {}

    public func rating(for url: URL) -> Int { ratings[url.standardizedFileURL.path, default: 0] }

    public mutating func rate(_ url: URL, stars: Int) {
        guard (0...5).contains(stars) else { return }
        ratings[url.standardizedFileURL.path] = stars == 0 ? nil : stars
    }

    public mutating func record(_ track: Track, at date: Date, retainingDays days: Int) {
        let path = track.url.standardizedFileURL.path
        var summary = summaries[path] ?? ListeningSummary(count: 0, lastPlayed: date)
        if summary.count < Int.max { summary.count += 1 }
        summary.lastPlayed = max(summary.lastPlayed, date)
        summaries[path] = summary
        events.append(ListeningEvent(id: UUID(), url: track.url, title: track.title, date: date))
        prune(at: date, retainingDays: days)
    }

    /// Удаление старых событий оставляет накопленный счётчик и последнюю дату.
    public mutating func prune(at date: Date, retainingDays days: Int) {
        guard days > 0 else { return }
        let cutoff = date.addingTimeInterval(-Double(days) * 86_400)
        events.removeAll { $0.date < cutoff }
    }

    public mutating func clearHistory() {
        events.removeAll()
        summaries.removeAll()
    }
}

public struct ListeningOptions: Codable, Equatable, Sendable {
    public var enabled = true
    public var thresholdSeconds = 30
    public var retentionDays = 90

    public init() {}
}

/// Учитывает только движение позиции во время активного воспроизведения.
/// Позиция после перемотки задаёт новую точку отсчёта, пауза сохраняет набранное время.
public struct ListeningSession {
    private var lastPosition: TimeInterval?
    private var lastTime: TimeInterval?
    private var listened: TimeInterval = 0
    private var recorded = false

    public init() {}

    public mutating func resume(at position: TimeInterval, time: TimeInterval) {
        lastPosition = position
        lastTime = time
    }

    public mutating func suspend() {
        lastPosition = nil
        lastTime = nil
    }

    public mutating func sample(position: TimeInterval, time: TimeInterval, duration: TimeInterval,
                                threshold: TimeInterval) -> Bool {
        guard !recorded, let previous = lastPosition, let previousTime = lastTime else { return false }
        resume(at: position, time: time)
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        listened += max(0, min(position - previous, time - previousTime))
        guard listened >= min(threshold, duration / 2) else { return false }
        recorded = true
        return true
    }
}

/// Раздельный файл сохраняет совместимость с библиотекой и её старыми версиями.
public struct ListeningActivityStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> ListeningActivity {
        guard FileManager.default.fileExists(atPath: url.path) else { return ListeningActivity() }
        return try JSONDecoder().decode(ListeningActivity.self, from: Data(contentsOf: url))
    }

    public func save(_ activity: ListeningActivity) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(activity).write(to: url, options: .atomic)
    }
}
