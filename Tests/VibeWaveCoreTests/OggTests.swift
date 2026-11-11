import AVFoundation
import XCTest
@testable import VibeWaveCore

/// Ogg Opus и Ogg Vorbis: разбор контейнера, заголовки, теги и точность декодера.
/// Эталоны: `opus.caf` содержит те же пакеты Opus, что и `tone.opus`; `tone.ogg` и `sweep.oga`
/// закодированы oggenc из PCM (см. docs/TESTING.md).
final class OggTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Checks/FormatFixtures")
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VibeWaveOgg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Реестр и разметка

    func testRegistryAcceptsOggExtensionsAsReadOnlyTags() {
        for name in ["a.ogg", "b.oga", "c.opus", "D.OPUS"] {
            XCTAssertEqual(AudioFormat(url: URL(fileURLWithPath: "/tmp/\(name)")), .ogg, name)
        }
        XCTAssertTrue(AudioFormat.ogg.readsTags)
        XCTAssertFalse(AudioFormat.ogg.writesTags)
        XCTAssertEqual(AudioFormat.ogg.contentTypes.map(\.identifier), ["org.xiph.ogg-audio"])
        XCTAssertTrue(Track.accepts(URL(fileURLWithPath: "/tmp/song.opus")))
    }

    func testCRCMatchesOggPolynomial() {
        // CRC-32, полином 0x04C11DB7, начальное значение 0, без отражения и финального XOR.
        XCTAssertEqual(OggCRC.checksum(Data("123456789".utf8)), 0x89A1_897F)
    }

    func testOpusPacketDurationsFromTOC() {
        XCTAssertEqual(OggAudioSource.opusFrames(Data([1 << 3])), 960)            // SILK 20 мс, один кадр
        XCTAssertEqual(OggAudioSource.opusFrames(Data([16 << 3 | 1])), 240)       // CELT 2,5 мс, два кадра
        XCTAssertEqual(OggAudioSource.opusFrames(Data([31 << 3 | 3, 3])), 2880)   // CELT 20 мс × 3
        XCTAssertEqual(OggAudioSource.opusFrames(Data([13 << 3 | 2])), 1920)      // Hybrid 20 мс × 2
        XCTAssertNil(OggAudioSource.opusFrames(Data([3 << 3 | 3, 4])))            // 4 × 60 мс > 120 мс
        XCTAssertNil(OggAudioSource.opusFrames(Data([31 << 3 | 3])))              // нет байта числа кадров
        XCTAssertNil(OggAudioSource.opusFrames(Data()))
    }

    func testXiphLacedCookie() {
        let cookie = OggAudioSource.xiphLaced([Data(count: 30), Data(count: 300), Data(count: 5)])
        XCTAssertEqual([UInt8](cookie.prefix(4)), [2, 30, 255, 45])
        XCTAssertEqual(cookie.count, 4 + 335)
    }

    // MARK: Контейнер

    func testStreamHeadersOfFixtures() throws {
        let opus = try OggStreamInfo.read(OggFileReader(url: fixtures.appendingPathComponent("tone.opus")))
        XCTAssertEqual(opus.codec, .opus)
        XCTAssertEqual(opus.channels, 2)
        XCTAssertEqual(opus.sampleRate, 48_000)
        XCTAssertEqual(opus.preSkip, 312)
        XCTAssertEqual(opus.lastGranule, 18_312)
        XCTAssertEqual(opus.headers.count, 2)

        let vorbis = try OggStreamInfo.read(OggFileReader(url: fixtures.appendingPathComponent("tone.ogg")))
        XCTAssertEqual(vorbis.codec, .vorbis)
        XCTAssertEqual(vorbis.channels, 2)
        XCTAssertEqual(vorbis.sampleRate, 48_000)
        XCTAssertEqual(vorbis.preSkip, 0)
        XCTAssertEqual(vorbis.lastGranule, 18_000)
        let blocks = try VorbisBlocks(identification: vorbis.headers[0], setup: vorbis.headers[2])
        XCTAssertEqual(blocks.shortBlock, 256)
        XCTAssertEqual(blocks.longBlock, 2048)
        XCTAssertEqual(blocks.longModes, [false, true])
    }

    func testPacketsAcrossPagesLacingAndForeignStreams() throws {
        // Пакет 70 000 байт занимает три страницы, пакет 510 байт оканчивается нулевым сегментом,
        // страницы чужого потока между ними пропускаются.
        let big = Data((0..<70_000).map { UInt8($0 % 251) })
        let exact = Data(repeating: 7, count: 510)
        var file = OggTestWriter(serial: 1)
        var foreign = OggTestWriter(serial: 2)
        file.page([Data("first".utf8)], granule: 10, flags: 2)
        file.append(foreign.pageData([Data("fishead".utf8)], granule: 0, flags: 2))
        file.page([big.prefix(255 * 120)], granule: -1, flags: 0, open: true)
        file.append(foreign.pageData([Data("noise".utf8)], granule: 5, flags: 0))
        file.page([big.dropFirst(255 * 120).prefix(255 * 120)], granule: -1, flags: 1, open: true)
        file.page([big.dropFirst(255 * 240), exact, Data("tail".utf8)], granule: 99, flags: 5)
        let url = folder.appendingPathComponent("packets.ogg")
        try file.data.write(to: url)

        let reader = try OggFileReader(url: url)
        var cursor = OggPacketCursor(serial: 1, offset: 0, resynchronized: false)
        var packets: [OggPacketCursor.Packet] = []
        while let packet = try cursor.next(reader) { packets.append(packet) }
        XCTAssertEqual(packets.map(\.data), [Data("first".utf8), big, exact, Data("tail".utf8)])
        XCTAssertEqual(packets.map(\.granule), [10, nil, nil, 99])
        XCTAssertEqual(packets.map(\.endsStream), [false, false, false, true])

        // Переход в середину: продолженный фрагмент отбрасывается до конца пакета.
        var own: [OggPage] = []
        var offset: UInt64 = 0
        while let page = try reader.page(at: offset) {
            if page.serial == 1 { own.append(page) }
            offset = page.end
        }
        XCTAssertEqual(own.map(\.continued), [false, false, true, true])
        let middle = own[2]
        var resumed = OggPacketCursor(serial: 1, offset: middle.offset, resynchronized: true)
        var rest: [Data] = []
        while let packet = try resumed.next(reader) { rest.append(packet.data) }
        XCTAssertEqual(rest, [exact, Data("tail".utf8)])
    }

    func testDamagedAndForeignFilesAreRejected() throws {
        let garbage = folder.appendingPathComponent("garbage.ogg")
        try Data(repeating: 0x42, count: 4096).write(to: garbage)
        XCTAssertThrowsError(try OggAudioSource(url: garbage)) { XCTAssertEqual($0 as? OggFailure, .notOgg) }

        var skeleton = OggTestWriter(serial: 3)
        skeleton.page([Data("fishead\0".utf8)], granule: 0, flags: 2)
        skeleton.page([Data("x".utf8)], granule: 0, flags: 4)
        let foreign = folder.appendingPathComponent("skeleton.ogg")
        try skeleton.data.write(to: foreign)
        XCTAssertThrowsError(try OggAudioSource(url: foreign)) { XCTAssertEqual($0 as? OggFailure, .notOgg) }

        // Один изменённый байт в середине звука ломает контрольную сумму страницы.
        var bytes = try [UInt8](Data(contentsOf: fixtures.appendingPathComponent("tone.opus")))
        bytes[bytes.count / 2] ^= 0x5A
        let damaged = folder.appendingPathComponent("damaged.opus")
        try Data(bytes).write(to: damaged)
        XCTAssertThrowsError(try {
            let source = try OggAudioSource(url: damaged)
            let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 20_000)!
            try source.read(into: buffer)
        }()) { XCTAssertEqual($0 as? OggFailure, .damaged) }

        // Многоканальный Opus (семейство 1) — понятный отказ «формат не поддерживается».
        let head = Data("OpusHead".utf8) + Data([1, 6, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 1, 4, 2, 0, 4, 1, 2, 3, 5])
        var multi = OggTestWriter(serial: 4)
        multi.page([head], granule: 0, flags: 2)
        multi.page([Data("OpusTags".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 0])], granule: 0, flags: 0)
        multi.page([Data([1 << 3, 0])], granule: 960, flags: 4)
        let surround = folder.appendingPathComponent("surround.opus")
        try multi.data.write(to: surround)
        XCTAssertThrowsError(try OggAudioSource(url: surround)) { XCTAssertEqual($0 as? OggFailure, .unsupportedStream) }
    }

    func testTruncatedAndChainedFiles() throws {
        let original = try Data(contentsOf: fixtures.appendingPathComponent("tone.opus"))
        let truncated = folder.appendingPathComponent("truncated.opus")
        try original.prefix(original.count - 100).write(to: truncated)
        let cut = try OggAudioSource(url: truncated)
        XCTAssertGreaterThan(cut.length, 0)
        XCTAssertLessThan(cut.length, 18_000)
        let all = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: cut.processingFormat, frameCapacity: 20_000))
        try cut.read(into: all)
        XCTAssertEqual(AVAudioFramePosition(all.frameLength), cut.length)

        // Цепочка из двух звеньев: играет первое, длина не включает второе.
        let chained = folder.appendingPathComponent("chained.opus")
        try (original + OggTestWriter.reserialized(original, serial: 77)).write(to: chained)
        let first = try OggAudioSource(url: chained)
        XCTAssertEqual(first.length, 18_000)
    }

    // MARK: Декодирование

    func testOpusMatchesCAFWithSamePacketsExactly() throws {
        let ogg = try OggAudioSource(url: fixtures.appendingPathComponent("tone.opus"))
        let caf = try AVAudioFile(forReading: fixtures.appendingPathComponent("opus.caf"))
        XCTAssertEqual(ogg.length, caf.length)
        XCTAssertEqual(ogg.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatOpus)
        XCTAssertTrue(ogg.processingFormat.isEqual(caf.processingFormat))
        let left = try samples(ogg), right = try samples(caf)
        XCTAssertEqual(left, right)
    }

    func testOpusOutputGainIsApplied() throws {
        // +6 дБ в OpusHead (Q7.8): значения PCM умножаются на 10^(6/20).
        let original = try Data(contentsOf: fixtures.appendingPathComponent("tone.opus"))
        let louder = folder.appendingPathComponent("gain.opus")
        try OggTestWriter.rewriteFirstPage(original) { body in
            body[16] = UInt8((6 * 256) & 0xFF)
            body[17] = UInt8((6 * 256) >> 8)
        }.write(to: louder)
        let base = try samples(OggAudioSource(url: fixtures.appendingPathComponent("tone.opus")))
        let gained = try samples(OggAudioSource(url: louder))
        let factor = Float(pow(10, 6.0 / 20))
        XCTAssertEqual(base.count, gained.count)
        for (plain, loud) in zip(base[0], gained[0]).prefix(5000) { XCTAssertEqual(loud, plain * factor, accuracy: 1e-6) }
    }

    func testVorbisMatchesSourcePCMWithoutOffset() throws {
        let ogg = try OggAudioSource(url: fixtures.appendingPathComponent("tone.ogg"))
        let wav = try AVAudioFile(forReading: fixtures.appendingPathComponent("tone.wav"))
        XCTAssertEqual(ogg.length, wav.length)
        XCTAssertEqual(ogg.fileFormat.streamDescription.pointee.mFormatID, OggAudioSource.vorbisFormat)
        let decoded = try samples(ogg), reference = try samples(wav)
        for channel in 0..<2 {
            var error: Float = 0, signal: Float = 0
            for (value, expected) in zip(decoded[channel], reference[channel]) {
                error += (value - expected) * (value - expected)
                signal += expected * expected
            }
            // Сдвиг даже на один кадр синуса дал бы ошибку порядка процентов.
            XCTAssertLessThan(error / signal, 1e-3, "канал \(channel)")
        }
    }

    func testSeekingMatchesContinuousDecoding() throws {
        // Малый порог поиска заставляет пройти деление пополам на коротких фикстурах.
        for (name, tolerance) in [("sweep.opus", Float(1e-4)), ("sweep.oga", Float(0)), ("tone.opus", Float(0)), ("tone.ogg", Float(0))] {
            let url = fixtures.appendingPathComponent(name)
            let linear = try samples(OggAudioSource(url: url, searchSpan: 4096))
            let source = try OggAudioSource(url: url, searchSpan: 4096)
            let length = source.length
            var positions: [AVAudioFramePosition] = [length - 1, 0, 1, length / 2, 959, 960, 961, length - 2000]
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for _ in 0..<30 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                positions.append(AVAudioFramePosition(state >> 33) % length)
            }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 1500))
            for position in positions where position >= 0 {
                source.framePosition = position
                try source.read(into: buffer)
                let expected = min(1500, Int(length - position))
                XCTAssertEqual(Int(buffer.frameLength), expected, "\(name) @\(position)")
                XCTAssertEqual(source.framePosition, position + AVAudioFramePosition(expected))
                for channel in 0..<2 {
                    for index in 0..<expected {
                        let difference = abs(buffer.floatChannelData![channel][index] - linear[channel][Int(position) + index])
                        if difference > tolerance {
                            XCTFail("\(name) @\(position)+\(index) канал \(channel): \(difference)")
                            return
                        }
                    }
                }
            }
            source.framePosition = length + 100
            XCTAssertEqual(source.framePosition, length)
            try source.read(into: buffer)
            XCTAssertEqual(buffer.frameLength, 0)
        }
    }

    func testLoudnessAnalysisReadsOgg() throws {
        let measurement = try LoudnessAnalyzer.analyze(fixtures.appendingPathComponent("sweep.oga"))
        XCTAssertNotNil(measurement.gain)
        XCTAssertGreaterThan(measurement.peak, 0.3)
    }

    // MARK: Теги

    func testOpusTagsArtworkAndR128() throws {
        let url = fixtures.appendingPathComponent("tone.opus")
        let tags = try AudioMetadataFile.read(url)
        XCTAssertEqual(tags.fields[.title], "Тест Opus")
        XCTAssertEqual(tags.fields[.artist], "VibeWave")
        XCTAssertEqual(tags.fields[.album], "Форматы")
        XCTAssertEqual(tags.fields[.track], "3")
        XCTAssertEqual(tags.fields[.year], "2026")
        // R128_TRACK_GAIN −2560 (−10 дБ к −23 LUFS) имеет приоритет над REPLAYGAIN_TRACK_GAIN.
        XCTAssertEqual(try XCTUnwrap(tags.replayGain.trackGain), -5, accuracy: 1e-9)
        XCTAssertEqual(tags.artwork?.mime, "image/png")
        XCTAssertEqual(tags.artwork?.width, 2)
        XCTAssertNil(try AudioMetadataFile.read(url, includeArtwork: false).artwork)
        XCTAssertThrowsError(try AudioMetadataFile.write({ var edit = AudioTagEdit(); edit.fields = [.title: "x"]; return edit }(), to: url))
    }

    func testVorbisTagsAndReplayGain() throws {
        let tags = try AudioMetadataFile.read(fixtures.appendingPathComponent("tone.ogg"))
        XCTAssertEqual(tags.fields[.title], "Тест Vorbis")
        XCTAssertEqual(tags.fields[.album], "Форматы")
        XCTAssertEqual(tags.fields[.track], "4")
        XCTAssertEqual(tags.replayGain.trackGain, -2.25)
        XCTAssertEqual(tags.replayGain.trackPeak, 0.5)
        XCTAssertNil(tags.artwork)
    }

    // MARK: Вспомогательное

    private func samples(_ source: AudioPCMSource) throws -> [[Float]] {
        source.framePosition = 0
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: buffer)
        XCTAssertEqual(AVAudioFramePosition(buffer.frameLength), source.length)
        return (0..<Int(source.processingFormat.channelCount)).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
    }
}

/// Минимальная запись страниц Ogg для синтетических случаев.
private struct OggTestWriter {
    let serial: UInt32
    private(set) var data = Data()
    private var sequence: UInt32 = 0

    init(serial: UInt32) { self.serial = serial }

    mutating func append(_ page: Data) { data.append(page) }

    /// `open` — последний пакет продолжается на следующей странице (без завершающего сегмента).
    mutating func page(_ packets: [Data], granule: Int64, flags: UInt8, open: Bool = false) {
        data.append(pageData(packets, granule: granule, flags: flags, open: open))
    }

    mutating func pageData(_ packets: [Data], granule: Int64, flags: UInt8, open: Bool = false) -> Data {
        var lacing: [UInt8] = []
        var body = Data()
        for (index, packet) in packets.enumerated() {
            var size = packet.count
            while size >= 255 { lacing.append(255); size -= 255 }
            if !(open && index == packets.count - 1) { lacing.append(UInt8(size)) }
            body.append(packet)
        }
        precondition(lacing.count <= 255)
        var page = Data("OggS".utf8) + Data([0, flags])
        withUnsafeBytes(of: granule.littleEndian) { page.append(contentsOf: $0) }
        withUnsafeBytes(of: serial.littleEndian) { page.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { page.append(contentsOf: $0) }
        page.append(contentsOf: [0, 0, 0, 0, UInt8(lacing.count)] + lacing)
        page.append(body)
        sequence += 1
        return Self.sealed(page)
    }

    static func sealed(_ page: Data) -> Data {
        var page = page
        page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        withUnsafeBytes(of: OggCRC.checksum(page).littleEndian) { page.replaceSubrange(22..<26, with: $0) }
        return page
    }

    static func pages(_ data: Data) -> [Data] {
        var result: [Data] = []
        var offset = 0
        while offset + 27 <= data.count {
            let segments = Int(data[offset + 26])
            let body = data[(offset + 27)..<(offset + 27 + segments)].reduce(0) { $0 + Int($1) }
            let size = 27 + segments + body
            result.append(data.subdata(in: offset..<offset + size))
            offset += size
        }
        return result
    }

    static func reserialized(_ data: Data, serial: UInt32) -> Data {
        pages(data).reduce(into: Data()) { result, page in
            var page = page
            withUnsafeBytes(of: serial.littleEndian) { page.replaceSubrange(14..<18, with: $0) }
            result.append(sealed(page))
        }
    }

    static func rewriteFirstPage(_ data: Data, _ change: (inout Data) -> Void) -> Data {
        var pages = pages(data)
        var page = pages[0]
        let header = 27 + Int(page[26])
        var body = page.subdata(in: header..<page.count)
        change(&body)
        page.replaceSubrange(header..<page.count, with: body)
        pages[0] = sealed(page)
        return pages.reduce(Data(), +)
    }
}
