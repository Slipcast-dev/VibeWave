import XCTest
@testable import VibeWaveCore

final class LibraryTests: XCTestCase {
    func testFormatsAndDuplicates() {
        let url = URL(fileURLWithPath: "/tmp/song.FLAC")
        XCTAssertTrue(Track.accepts(url))
        XCTAssertFalse(Track.accepts(URL(fileURLWithPath: "/tmp/song.wav")))
        XCTAssertFalse(Track.accepts(URL(string: "https://example.com/song.mp3")!))
        var playlist = Playlist(name: "Тест")
        playlist.append(Track(url: url, duration: 180))
        playlist.append(Track(url: url, duration: 180))
        XCTAssertEqual(playlist.tracks.count, 1)
    }

    func testPersistenceAndCorruptionProtection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        XCTAssertTrue(try store.load().isEmpty)
        let playlists = [Playlist(name: "Вечер", tracks: [Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), duration: 30)])]
        try store.save(playlists)
        XCTAssertEqual(try store.load(), playlists)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.url), "broken")
    }

    func testMovingTracksAndPersistingOrder() throws {
        let a = Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), duration: 1)
        let b = Track(url: URL(fileURLWithPath: "/tmp/b.flac"), duration: 2)
        let c = Track(url: URL(fileURLWithPath: "/tmp/c.mp3"), duration: 3)
        var playlist = Playlist(name: "Порядок", tracks: [a, b, c])
        XCTAssertTrue(playlist.moveTrack(a.id, before: c.id))
        XCTAssertEqual(playlist.tracks, [b, a, c])
        XCTAssertTrue(playlist.moveTrack(c.id, before: b.id))
        XCTAssertEqual(playlist.tracks, [c, b, a])
        XCTAssertTrue(playlist.moveTrack(c.id, before: nil))
        XCTAssertEqual(playlist.tracks, [b, a, c])
        XCTAssertFalse(playlist.moveTrack(a.id, before: a.id))
        XCTAssertFalse(playlist.moveTrack(UUID(), before: nil))
        XCTAssertFalse(playlist.moveTrack(a.id, before: UUID()))
        XCTAssertEqual(playlist.tracks, [b, a, c])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        try store.save([playlist])
        XCTAssertEqual(try store.load(), [playlist])
    }

    func testTimeLabels() {
        XCTAssertEqual(timeLabel(84), "1:24")
        XCTAssertEqual(timeLabel(-10), "0:00")
        XCTAssertEqual(timeLabel(.nan), "0:00")
        XCTAssertEqual(timeLabel(3600), "60:00")
    }
}
