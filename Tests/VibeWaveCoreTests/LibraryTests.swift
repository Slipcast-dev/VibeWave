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

    func testManualOrderAndSnapshotCompatibility() throws {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(ManualOrder.arrange(ids, order: [ids[2], ids[0]], id: { $0 }), [ids[2], ids[0], ids[1], ids[3]])
        XCTAssertEqual(ManualOrder.move(ids[3], before: ids[0], in: ids), [ids[3], ids[0], ids[1], ids[2]])
        XCTAssertEqual(ManualOrder.move(ids[0], before: nil, in: ids), [ids[1], ids[2], ids[3], ids[0]])
        XCTAssertNil(ManualOrder.move(ids[0], before: ids[0], in: ids))
        XCTAssertNil(ManualOrder.move(UUID(), before: nil, in: ids))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        let track = Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), duration: 1)
        let snapshot = LibrarySnapshot(playlists: [Playlist(name: "A")],
                                       folders: [MusicFolder(url: URL(fileURLWithPath: "/tmp/music"), tracks: [track])],
                                       order: [track.id])
        try store.save(snapshot)
        XCTAssertEqual(try store.loadSnapshot(), snapshot)
        XCTAssertEqual(try store.load(), snapshot.playlists)
        var music = snapshot.folders[0]
        let added = Track(url: URL(fileURLWithPath: "/tmp/music/b.mp3"), duration: 2)
        music.merge(scanned: [Track(url: track.url, duration: 1), added])
        XCTAssertEqual(music.tracks.map(\.id), [track.id, added.id])
    }

    func testMusicFilesKeepsOnlyRegularVisibleFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Album.mp3/Disc"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Player.app"), withIntermediateDirectories: true)
        for name in ["Track 10.mp3", "Track 2.FLAC", "notes.txt", ".hidden.mp3", "Album.mp3/Disc/inner.flac", "Player.app/bundled.mp3"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        try manager.createSymbolicLink(at: root.appendingPathComponent("link.mp3"),
                                       withDestinationURL: root.appendingPathComponent("Track 10.mp3"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("dir-link.mp3"),
                                       withDestinationURL: root.appendingPathComponent("Album.mp3"))
        let files = try XCTUnwrap(try MusicFiles.collect(in: root))
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["Track 10.mp3", "Track 2.FLAC", "inner.flac", "link.mp3"])
        let tracks = files.map(\.lastPathComponent).filter { $0.hasPrefix("Track") }
        XCTAssertEqual(tracks, ["Track 2.FLAC", "Track 10.mp3"], "Порядок как в Finder")
        XCTAssertNil(try MusicFiles.collect(in: root.appendingPathComponent("missing")))
        XCTAssertNil(try MusicFiles.collect(in: root.appendingPathComponent("notes.txt")))
        XCTAssertThrowsError(try MusicFiles.collect(in: root, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testFolderMergeWithoutRereadingKnownFiles() {
        let a = Track(url: URL(fileURLWithPath: "/music/a.mp3"), duration: 1)
        let b = Track(url: URL(fileURLWithPath: "/music/b.mp3"), duration: 2)
        var folder = MusicFolder(url: URL(fileURLWithPath: "/music"), tracks: [b, a])
        let c = Track(url: URL(fileURLWithPath: "/music/c.mp3"), duration: 3)
        // b исчез с диска, a известен, c новый; повторное чтение a не нужно.
        folder.merge(files: [a.url, c.url], added: [c])
        XCTAssertEqual(folder.tracks, [a, c])
        // Запись для файла, которого нет в списке, не добавляется; дубликаты отбрасываются.
        folder.merge(files: [a.url, c.url], added: [Track(url: c.url, duration: 3), b])
        XCTAssertEqual(folder.tracks, [a, c])
    }

    func testLanguageFollowsSystemPreferences() {
        XCTAssertEqual(AppLanguage.preferred(from: ["ru-RU", "en-US"]), .ru)
        XCTAssertEqual(AppLanguage.preferred(from: ["en-GB", "ru"]), .en)
        XCTAssertEqual(AppLanguage.preferred(from: ["de-DE", "ru_RU"]), .ru, "Первый поддерживаемый язык из списка")
        XCTAssertEqual(AppLanguage.preferred(from: ["uk-UA", "fr"]), .en, "Без русского и английского — английский")
        XCTAssertEqual(AppLanguage.preferred(from: []), .en)
        XCTAssertEqual(LanguagePreference.system.resolve(systemLanguages: ["ru-RU"]), .ru)
        XCTAssertEqual(LanguagePreference.en.resolve(systemLanguages: ["ru-RU"]), .en)
        XCTAssertEqual(LanguagePreference.ru.resolve(systemLanguages: ["en-US"]), .ru)
    }

    func testStringsForBothLanguages() {
        XCTAssertEqual(Strings.for(.ru).allMusic, "Вся музыка")
        XCTAssertEqual(Strings.for(.en).allMusic, "All Music")
        XCTAssertEqual(Strings.ru.progressCount("Чтение файлов", 3, 10), "Чтение файлов: 3 из 10")
        XCTAssertEqual(Strings.en.progressCount("Reading files", 3, 10), "Reading files: 3 of 10")
        XCTAssertEqual(Strings.ru.errorCouldNotOpen(["a.mp3"], 0), "Не удалось открыть: a.mp3")
        XCTAssertEqual(Strings.en.errorCouldNotOpen(["a.mp3", "b.flac"], 4), "Couldn’t open: a.mp3, b.flac and 4 more")
        XCTAssertEqual(Strings.en.languageSystem(AppLanguage.ru.nativeName), "System (Русский)")
        XCTAssertEqual(AppLanguage.en.code, "EN")
    }

    func testEqualizerSettingsStayInRange() throws {
        var settings = EqualizerSettings(enabled: true, preamp: 40, gains: [20, -20, 3])
        XCTAssertEqual(settings.preamp, 12)
        XCTAssertEqual(settings.gains, [12, -12, 3, 0, 0, 0, 0, 0, 0, 0], "Ровно 10 полос в пределах ±12 дБ")
        settings.gains[4] = -99
        XCTAssertEqual(settings.gains[4], -12)
        settings.gains = Array(repeating: 1, count: 14)
        XCTAssertEqual(settings.gains.count, EqualizerSettings.frequencies.count)
        XCTAssertNil(settings.preset)
        XCTAssertEqual(EqualizerSettings(preset: .rock).preset, .rock)
        XCTAssertEqual(EqualizerSettings().preset, .flat)
        XCTAssertFalse(EqualizerSettings().enabled)
        for preset in EqualizerPreset.allCases {
            XCTAssertEqual(preset.gains.count, EqualizerSettings.frequencies.count, preset.rawValue)
            XCTAssertTrue(preset.gains.allSatisfy(EqualizerSettings.gainRange.contains), preset.rawValue)
            XCTAssertFalse(Strings.ru.eqPresetName(preset).isEmpty)
            XCTAssertNotEqual(Strings.ru.eqPresetName(preset), Strings.en.eqPresetName(preset), preset.rawValue)
        }
        // Сохранённые настройки читаются и с неполными или испорченными значениями.
        let restored = try JSONDecoder().decode(EqualizerSettings.self, from: Data(#"{"gains":[3,99]}"#.utf8))
        XCTAssertEqual(restored, EqualizerSettings(enabled: false, preamp: 0, gains: [3, 12]))
        let roundTrip = try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(EqualizerSettings(preset: .vocal)))
        XCTAssertEqual(roundTrip, EqualizerSettings(preset: .vocal))
        XCTAssertEqual(Strings.ru.eqDecibels(3), "+3 дБ")
        XCTAssertEqual(Strings.en.eqDecibels(-0.2), "0 dB")
    }

    func testTimeLabels() {
        XCTAssertEqual(timeLabel(84), "1:24")
        XCTAssertEqual(timeLabel(-10), "0:00")
        XCTAssertEqual(timeLabel(.nan), "0:00")
        XCTAssertEqual(timeLabel(3600), "60:00")
    }
}
