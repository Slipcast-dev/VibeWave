import AVFoundation
import XCTest
@testable import VibeWaveCore

/// Устойчивость к повреждённым файлам, восстановление библиотеки и подписи обновлений.
/// Фаззинг детерминированный (фиксированное зерно), поэтому падение воспроизводится.
final class RobustnessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VibeWaveRobustness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func copy(_ path: String, as name: String) throws -> URL {
        let target = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.root.appendingPathComponent(path), to: target)
        return target
    }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    // MARK: Теги

    func testTagEditsRoundTripForMP3AndFLAC() throws {
        for (path, name) in [("Checks/Fixtures/silence.mp3", "tags.mp3"), ("Checks/Fixtures/silence.flac", "tags.flac")] {
            let url = try copy(path, as: name)
            var edit = AudioTagEdit()
            edit.fields = [.title: "Название «тест»", .artist: "Исполнитель", .album: "Album", .year: "2026",
                           .track: "3/12", .disc: "1/2", .genre: "Ambient", .comment: "Комментарий"]
            edit.artwork = .replace(AudioArtwork(data: Self.png, mime: "image/png", width: 1, height: 1))
            let written = try AudioMetadataFile.write(edit, to: url)
            XCTAssertEqual(written.fields[.title], "Название «тест»", name)
            let read = try AudioMetadataFile.read(url)
            for (field, value) in edit.fields { XCTAssertEqual(read.fields[field], value, "\(name) \(field)") }
            XCTAssertEqual(read.artwork?.data, Self.png, name)
            // Звук после записи тегов по-прежнему открывается.
            XCTAssertNoThrow(try AVAudioFile(forReading: url), name)

            var removal = AudioTagEdit()
            removal.artwork = .remove
            removal.fields = [.comment: ""]
            _ = try AudioMetadataFile.write(removal, to: url)
            let cleared = try AudioMetadataFile.read(url)
            XCTAssertNil(cleared.artwork, name)
            XCTAssertNil(cleared.fields[.comment], name)
            XCTAssertEqual(cleared.fields[.artist], "Исполнитель", name)
        }
    }

    func testRejectsInvalidTagValuesWithoutTouchingFile() throws {
        let url = try copy("Checks/Fixtures/silence.mp3", as: "invalid.mp3")
        let before = try Data(contentsOf: url)
        for (field, value) in [(AudioTagField.year, "20x6"), (.track, "0"), (.title, "a\0b")] {
            var edit = AudioTagEdit()
            edit.fields = [field: value]
            XCTAssertThrowsError(try AudioMetadataFile.write(edit, to: url), "\(field)")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    // MARK: Фаззинг

    /// Повреждённые копии: побитовые замены в начале файла, случайные замены по всему файлу,
    /// обрезка и «граничные» байты. Разбор не должен падать; ошибки допустимы.
    func testDamagedFilesNeverCrashParsersOrDecoder() throws {
        let tagged = try copy("Checks/Fixtures/silence.mp3", as: "seed.mp3")
        var edit = AudioTagEdit()
        edit.fields = [.title: "Seed", .comment: "Comment", .artist: "Artist"]
        edit.artwork = .replace(AudioArtwork(data: Self.png, mime: "image/png", width: 1, height: 1))
        edit.replayGain = ReplayGainValues(trackGain: -3, albumGain: -4, trackPeak: 0.9, albumPeak: 0.95)
        _ = try AudioMetadataFile.write(edit, to: tagged)
        let taggedFLAC = try copy("Checks/Fixtures/silence.flac", as: "seed.flac")
        _ = try AudioMetadataFile.write(edit, to: taggedFLAC)

        let seeds: [URL] = [tagged, taggedFLAC,
                            try copy("Checks/FormatFixtures/tone.ogg", as: "seed.ogg"),
                            try copy("Checks/FormatFixtures/tone.opus", as: "seed.opus"),
                            try copy("Checks/FormatFixtures/sweep.oga", as: "seed.oga")]
        var random = SplitMix64(seed: 0x5642_5761_7665)
        var outcomes = 0
        for seed in seeds {
            let original = try Data(contentsOf: seed)
            let sample = folder.appendingPathComponent("case." + seed.pathExtension)
            for iteration in 0..<300 {
                var data = original
                switch iteration % 4 {
                case 0:
                    for _ in 0..<random.int(1...8) { data[random.int(0...min(data.count, 4096) - 1)] = random.byte() }
                case 1:
                    data = data.prefix(random.int(0...data.count))
                case 2:
                    for _ in 0..<random.int(1...32) { data[random.int(0...data.count - 1)] = random.byte() }
                default:
                    let start = random.int(0...min(data.count, 512) - 1)
                    for index in start..<min(data.count, start + 4) { data[index] = [0x00, 0xFF, 0x7F, 0x80][random.int(0...3)] }
                }
                try data.write(to: sample)
                if (try? AudioMetadataFile.read(sample)) != nil { outcomes += 1 }
                if seed.pathExtension != "mp3" && seed.pathExtension != "flac", let source = try? OggAudioSource(url: sample),
                   let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096) {
                    for _ in 0..<16 {
                        guard (try? source.read(into: buffer, frameCount: 4096)) != nil, buffer.frameLength > 0 else { break }
                    }
                    source.framePosition = source.length / 2
                    _ = try? source.read(into: buffer, frameCount: 4096)
                    outcomes += 1
                }
            }
        }
        // Часть случаев должна оставаться читаемой: иначе мутации проверяли бы только первую проверку формата.
        XCTAssertGreaterThan(outcomes, 100)
    }

    func testStreamingCRCMatchesWholeBufferCRC() {
        var random = SplitMix64(seed: 42)
        let data = Data((0..<10_000).map { _ in random.byte() })
        let split = OggCRC.update(OggCRC.update(0, data.prefix(3_333)), data.dropFirst(3_333))
        XCTAssertEqual(split, OggCRC.checksum(data))
    }

    // MARK: Библиотека

    func testDamagedLibraryIsSetAsideAndRestoredFromBackup() throws {
        let store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        let snapshot = LibrarySnapshot(playlists: [Playlist(name: "Сохранённый")])
        try store.save(snapshot)
        XCTAssertEqual(try store.loadSnapshot(), snapshot)
        try store.backUp()
        try Data("{\"playlists\": [ oops".utf8).write(to: store.url)

        XCTAssertThrowsError(try store.loadSnapshot()) { XCTAssertTrue(LibraryStore.isDamaged($0)) }
        let recovery = try store.recoverFromDamage(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(recovery.snapshot, snapshot)
        XCTAssertEqual(try store.loadSnapshot(), snapshot, "Основной файл восстановлен из копии")
        XCTAssertEqual(try String(contentsOf: recovery.damagedCopy), "{\"playlists\": [ oops", "Повреждённый файл не удалён")
    }

    func testDamagedLibraryWithoutBackupStartsEmptyAndKeepsDamagedCopy() throws {
        let store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        try Data().write(to: store.url)
        XCTAssertThrowsError(try store.loadSnapshot()) { XCTAssertTrue(LibraryStore.isDamaged($0)) }
        let recovery = try store.recoverFromDamage()
        XCTAssertNil(recovery.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.damagedCopy.path))
    }

    func testUnreadableLibraryIsNotTreatedAsDamaged() {
        XCTAssertFalse(LibraryStore.isDamaged(CocoaError(.fileReadNoPermission)))
    }

    func testLegacyLibraryWithLeadingWhitespaceIsRead() throws {
        let url = folder.appendingPathComponent("library.json")
        let playlists = [Playlist(name: "Старый формат")]
        try (Data("\n  ".utf8) + JSONEncoder().encode(playlists)).write(to: url)
        XCTAssertEqual(try LibraryStore(url: url).load(), playlists)
    }

    // MARK: Обновления

    func testManifestSignatureCoversEveryFieldAndSurvivesJSON() throws {
        let keys = UpdateSignature.generateKeyPair()
        let archive = Data("archive".utf8)
        let unsigned = UpdateManifest(version: "2.2.0", url: URL(string: "https://example.invalid/a.zip")!,
                                      sha256: UpdateSignature.sha256Hex(archive),
                                      signature: try UpdateSignature.sign(archive, privateKey: keys.privateKey),
                                      notes: ["ru": "Исправления", "en": "Fixes"])
        XCTAssertThrowsError(try UpdateSignature.verifyManifest(unsigned, publicKeys: [keys.publicKey]))
        let signed = try UpdateSignature.signManifest(unsigned, privateKey: keys.privateKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let decoded = try JSONDecoder().decode(UpdateManifest.self, from: encoder.encode(signed))
        XCTAssertNoThrow(try UpdateSignature.verifyManifest(decoded, publicKeys: [keys.publicKey]))
        XCTAssertNoThrow(try UpdateSignature.verify(archive, manifest: decoded, publicKeys: [keys.publicKey]))

        let mutations: [(inout UpdateManifest) -> Void] = [
            { $0.version = "9.9.9" }, { $0.url = URL(string: "https://example.invalid/b.zip")! },
            { $0.minimumSystemVersion = "26.0" }, { $0.notes["ru"] = "Другое" }, { $0.notes["de"] = "Neu" },
            { $0.sha256 = String(repeating: "0", count: 64) }
        ]
        for mutate in mutations {
            var forged = decoded
            mutate(&forged)
            XCTAssertThrowsError(try UpdateSignature.verifyManifest(forged, publicKeys: [keys.publicKey]))
        }
        // Ротация ключей: любой из доверенных ключей; неверный ключ в списке — ошибка конфигурации.
        let other = UpdateSignature.generateKeyPair()
        XCTAssertNoThrow(try UpdateSignature.verifyManifest(decoded, publicKeys: [other.publicKey, keys.publicKey]))
        XCTAssertThrowsError(try UpdateSignature.verifyManifest(decoded, publicKeys: [other.publicKey]))
        XCTAssertThrowsError(try UpdateSignature.verifyManifest(decoded, publicKeys: ["not a key", keys.publicKey]))
    }

    func testOldManifestWithoutSignatureStillDecodes() throws {
        let json = #"{"version":"2.1.1","url":"https://example.invalid/a.zip","sha256":"00","signature":"AA=="}"#
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.manifestSignature)
    }
}

/// Детерминированный генератор для воспроизводимого фаззинга.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        guard range.upperBound > range.lowerBound else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}
