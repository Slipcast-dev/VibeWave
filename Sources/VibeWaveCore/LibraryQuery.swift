import Foundation

public enum QueryField: String, CaseIterable, Codable, Identifiable, Sendable {
    case title, artist, album, genre, filename, path, format, year, rating, duration, added, lastPlayed, plays

    public var id: Self { self }
    public var operators: [QueryOperator] {
        switch self {
        case .year, .rating, .duration, .plays: return [.equals, .atLeast, .atMost]
        case .added, .lastPlayed: return [.withinDays, .olderThanDays, .exists, .missing]
        default: return [.contains, .equals, .notEquals]
        }
    }

    public static let textSearchFields: [Self] = [.title, .artist, .album, .genre, .filename, .path]
}

public enum QueryOperator: String, Codable, Identifiable, Sendable {
    case contains, equals, notEquals, atLeast, atMost, withinDays, olderThanDays, exists, missing
    public var id: Self { self }
    public var requiresValue: Bool { self != .exists && self != .missing }
}

public struct QueryRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var field: QueryField
    public var operation: QueryOperator
    public var value: String

    public init(_ field: QueryField = .title, _ operation: QueryOperator = .contains, _ value: String = "") {
        self.field = field
        self.operation = operation
        self.value = value
    }

    public var isValid: Bool {
        guard field.operators.contains(operation) else { return false }
        guard operation.requiresValue else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if field.operators.contains(.atLeast) || field.operators.contains(.withinDays) {
            guard let number = Double(trimmed.replacingOccurrences(of: ",", with: ".")), number.isFinite,
                  number >= 0 else { return false }
            if operation == .withinDays || operation == .olderThanDays { return number <= 365_000 }
        }
        return true
    }
}

public struct LibraryQuery: Codable, Equatable, Sendable {
    public var rules: [QueryRule] = []
    public var matchAny = false
    public var sort: QueryField?
    /// nil сохраняет наследование настроек поиска в старых данных.
    public var preservesInputOrder: Bool?
    public var descending = false
    public var limit = 0

    public init() {}

    public var isActive: Bool { !rules.isEmpty || sort != nil || limit > 0 }
    public var isValid: Bool { rules.allSatisfy(\.isValid) && (0...100_000).contains(limit) }

    /// При равных значениях исходный порядок сохраняется независимо от направления.
    public func apply(to records: [QueryRecord], text: String = "", fields: Set<QueryField> = Set(QueryField.textSearchFields),
                      now: Date = Date()) -> [QueryRecord] {
        let query = Self.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var results = records.filter { record in
            let matchesText = query.isEmpty || fields.contains { Self.fold(record.text($0)).contains(query) }
                || (fields.contains(.title) && Self.fold(record.track.title).contains(query))
            guard matchesText else { return false }
            if rules.isEmpty { return true }
            if matchAny { return rules.contains { $0.matches(record, now: now) } }
            return rules.allSatisfy { $0.matches(record, now: now) }
        }
        if let sort = sort {
            results = results.enumerated().sorted { lhs, rhs in
                let order = lhs.element.compare(to: rhs.element, by: sort)
                if order == .orderedSame { return lhs.offset < rhs.offset }
                return descending ? order == .orderedDescending : order == .orderedAscending
            }.map(\.element)
        }
        return limit > 0 ? Array(results.prefix(limit)) : results
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct SmartPlaylist: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var query = LibraryQuery()
    public init() {}
}

public enum SearchScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case section, library
    public var id: Self { self }
}

public struct SearchOptions: Codable, Equatable, Sendable {
    public var scope: SearchScope = .section
    public var fields = Set(QueryField.textSearchFields)
    public var sort: QueryField?
    public init() {}
}

public struct QueryRecord: Sendable {
    public let track: Track
    public let sourceID: UUID?
    public let tags: [AudioTagField: String]
    public let rating: Int
    public let history: ListeningSummary?

    public init(track: Track, sourceID: UUID?, tags: [AudioTagField: String], rating: Int, history: ListeningSummary?) {
        self.track = track
        self.sourceID = sourceID
        self.tags = tags
        self.rating = rating
        self.history = history
    }

    func text(_ field: QueryField) -> String {
        switch field {
        case .title: return tags[.title] ?? track.title
        case .artist: return tags[.artist] ?? ""
        case .album: return tags[.album] ?? ""
        case .genre: return tags[.genre] ?? ""
        case .filename: return track.url.lastPathComponent
        case .path: return track.url.path
        case .format: return track.url.pathExtension
        default: return ""
        }
    }

    func number(_ field: QueryField) -> Double? {
        switch field {
        case .year: return tags[.year].flatMap { Double($0.prefix(4)) }
        case .rating: return Double(rating)
        case .duration: return track.duration
        case .plays: return Double(history?.count ?? 0)
        default: return nil
        }
    }

    func date(_ field: QueryField) -> Date? {
        switch field {
        case .added: return track.addedAt
        case .lastPlayed: return history?.lastPlayed
        default: return nil
        }
    }

    func compare(to other: Self, by field: QueryField) -> ComparisonResult {
        if field.operators.contains(.atLeast) { return Self.order(number(field), other.number(field)) }
        if field.operators.contains(.withinDays) { return Self.order(date(field), other.date(field)) }
        return text(field).localizedStandardCompare(other.text(field))
    }

    private static func order<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none): return .orderedSame
        case (.none, .some): return .orderedAscending
        case (.some, .none): return .orderedDescending
        case let (.some(a), .some(b)): return a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
        }
    }
}

private extension QueryRule {
    func matches(_ record: QueryRecord, now: Date) -> Bool {
        guard isValid else { return false }
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation == .exists { return record.date(field) != nil }
        if operation == .missing { return record.date(field) == nil }
        if let days = Double(input.replacingOccurrences(of: ",", with: ".")) {
            if operation == .withinDays || operation == .olderThanDays {
                guard let date = record.date(field) else { return false }
                let cutoff = now.addingTimeInterval(-days * 86_400)
                return operation == .withinDays ? (cutoff...now).contains(date) : date < cutoff
            }
            if field.operators.contains(.atLeast) {
                guard let number = record.number(field) else { return false }
                switch operation {
                case .atLeast: return number >= days
                case .atMost: return number <= days
                default: return number == days
                }
            }
        }
        let needle = LibraryQuery.fold(input)
        let candidate = LibraryQuery.fold(record.text(field))
        switch operation {
        case .contains: return candidate.contains(needle)
        case .notEquals: return candidate != needle
        default: return candidate == needle
        }
    }
}
