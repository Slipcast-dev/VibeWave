import XCTest
@testable import VibeWaveCore

final class LibraryQueryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ name: String, artist: String, year: String? = nil, rating: Int = 0,
                        duration: Double = 100, added: Date? = nil, plays: Int? = nil) -> QueryRecord {
        var tags: [AudioTagField: String] = [.artist: artist]
        tags[.year] = year
        let history = plays.map { ListeningSummary(count: $0, lastPlayed: now) }
        return QueryRecord(track: Track(url: URL(fileURLWithPath: "/m/\(name).mp3"), duration: duration, addedAt: added),
                           sourceID: nil, tags: tags, rating: rating, history: history)
    }

    func testTextSearchIgnoresCaseAndDiacritics() {
        let records = [record("Café", artist: "Ёлка"), record("Other", artist: "Zed")]
        XCTAssertEqual(LibraryQuery().apply(to: records, text: "cafe").map(\.track.title), ["Café"])
        XCTAssertEqual(LibraryQuery().apply(to: records, text: "ЁЛКА").map(\.track.title), ["Café"])
    }

    func testAllAndAnyRules() {
        let records = [record("a", artist: "X", year: "1999", rating: 5),
                       record("b", artist: "Y", year: "2005", rating: 2),
                       record("c", artist: "X", year: "2010", rating: 1)]
        var query = LibraryQuery()
        query.rules = [QueryRule(.artist, .equals, "x"), QueryRule(.year, .atLeast, "2000")]
        XCTAssertEqual(query.apply(to: records).map(\.track.title), ["c"])
        query.matchAny = true
        XCTAssertEqual(query.apply(to: records).map(\.track.title), ["a", "b", "c"])
        query.rules = [QueryRule(.rating, .atLeast, "5"), QueryRule(.year, .atMost, "2005")]
        query.matchAny = false
        XCTAssertEqual(query.apply(to: records).map(\.track.title), ["a"])
    }

    func testDateRulesUseNowAndMissingValues() {
        let records = [record("new", artist: "", added: now.addingTimeInterval(-86_400)),
                       record("old", artist: "", added: now.addingTimeInterval(-40 * 86_400)),
                       record("legacy", artist: "")]
        var query = LibraryQuery()
        query.rules = [QueryRule(.added, .withinDays, "7")]
        XCTAssertEqual(query.apply(to: records, now: now).map(\.track.title), ["new"])
        query.rules = [QueryRule(.added, .olderThanDays, "30")]
        XCTAssertEqual(query.apply(to: records, now: now).map(\.track.title), ["old"])
        query.rules = [QueryRule(.added, .missing)]
        XCTAssertEqual(query.apply(to: records, now: now).map(\.track.title), ["legacy"])
    }

    func testStableSortDescendingAndLimit() {
        let records = [record("a", artist: "", duration: 30), record("b", artist: "", duration: 90),
                       record("c", artist: "", duration: 30), record("d", artist: "", duration: 60)]
        var query = LibraryQuery()
        query.sort = .duration
        XCTAssertEqual(query.apply(to: records).map(\.track.title), ["a", "c", "d", "b"])
        query.descending = true
        XCTAssertEqual(query.apply(to: records).map(\.track.title), ["b", "d", "a", "c"])
        query.limit = 2
        XCTAssertEqual(query.apply(to: records).map(\.track.title), ["b", "d"])
    }

    func testInvalidRulesMatchNothing() {
        XCTAssertFalse(QueryRule(.year, .atLeast, "abc").isValid)
        XCTAssertFalse(QueryRule(.title, .atLeast, "1").isValid)
        XCTAssertFalse(QueryRule(.added, .withinDays, "-1").isValid)
        XCTAssertTrue(QueryRule(.duration, .atMost, "2,5").isValid)
        var query = LibraryQuery()
        query.rules = [QueryRule(.year, .atLeast, "abc")]
        XCTAssertFalse(query.isValid)
        XCTAssertTrue(query.apply(to: [record("a", artist: "", year: "2000")]).isEmpty)
    }
}
