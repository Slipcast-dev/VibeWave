import XCTest
@testable import VibeWaveCore

final class PlaylistFileTests: XCTestCase {
    func testM3UReadsTitlesAndSkipsComments() throws {
        let text = "#EXTM3U\n#EXTINF:84,Первая песня\nmusic/a.mp3\n# комментарий\n\nb.flac\n"
        let entries = try PlaylistFile.decode(Data(text.utf8), format: .m3u8, legacyEncoding: .windows1251)
        XCTAssertEqual(entries, [PlaylistFile.Entry(path: "music/a.mp3", title: "Первая песня"),
                                 PlaylistFile.Entry(path: "b.flac", title: nil)])
    }

    func testHLSManifestIsRejected() {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:10\nsegment.ts\n"
        XCTAssertThrowsError(try PlaylistFile.decode(Data(text.utf8), format: .m3u, legacyEncoding: .utf8)) {
            XCTAssertEqual($0 as? PlaylistFile.Failure, .streamingManifest)
        }
    }

    func testLegacyEncodingIsUsedOnlyOutsideM3U8() throws {
        let data = try XCTUnwrap("Трек.mp3\n".data(using: .windowsCP1251))
        let entries = try PlaylistFile.decode(data, format: .m3u, legacyEncoding: .windows1251)
        XCTAssertEqual(entries.map(\.path), ["Трек.mp3"])
        XCTAssertThrowsError(try PlaylistFile.decode(data, format: .m3u8, legacyEncoding: .windows1251))
    }

    func testPLSOrdersByIndexAndRequiresHeader() throws {
        let text = "[playlist]\nFile2=b.mp3\nTitle2=B\nFile1=a.mp3\nNumberOfEntries=2\n"
        let entries = try PlaylistFile.decode(Data(text.utf8), format: .pls, legacyEncoding: .utf8)
        XCTAssertEqual(entries, [PlaylistFile.Entry(path: "a.mp3", title: nil), PlaylistFile.Entry(path: "b.mp3", title: "B")])
        XCTAssertThrowsError(try PlaylistFile.decode(Data("File1=a.mp3\n".utf8), format: .pls, legacyEncoding: .utf8))
    }

    func testRemoteAndUNCPathsAreNotLocal() {
        let playlist = URL(fileURLWithPath: "/tmp/list.m3u8")
        XCTAssertNil(PlaylistFile.localURL(for: .init(path: "https://example.com/a.mp3", title: nil), in: playlist))
        XCTAssertNil(PlaylistFile.localURL(for: .init(path: "\\\\server\\share\\a.mp3", title: nil), in: playlist))
        XCTAssertEqual(PlaylistFile.localURL(for: .init(path: "sub/a.mp3", title: nil), in: playlist)?.path, "/tmp/sub/a.mp3")
    }

    func testRelativeExportRoundTrip() throws {
        let destination = URL(fileURLWithPath: "/Music/Lists/mix.m3u8")
        let tracks = [Track(url: URL(fileURLWithPath: "/Music/Lists/near.mp3"), duration: 61.9),
                      Track(url: URL(fileURLWithPath: "/Music/Album/#1 hit.flac"), duration: 120)]
        let data = try PlaylistFile.encode(tracks, destination: destination, options: PlaylistFileOptions())
        let entries = try PlaylistFile.decode(data, format: .m3u8, legacyEncoding: .utf8)
        XCTAssertEqual(entries.map(\.path), ["./near.mp3", "../Album/#1 hit.flac"])
        XCTAssertEqual(entries.map(\.title), ["near", "#1 hit"])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("#EXTINF:61,near"))
    }

    func testLossyLegacyExportIsRefused() {
        var options = PlaylistFileOptions()
        options.exportEncoding = .windows1251
        let track = Track(url: URL(fileURLWithPath: "/Music/日本.mp3"), duration: 1)
        XCTAssertThrowsError(try PlaylistFile.encode([track], destination: URL(fileURLWithPath: "/Music/a.m3u"), options: options)) {
            XCTAssertEqual($0 as? PlaylistFile.Failure, .lossyEncoding)
        }
    }
}
