import AVFoundation
import XCTest
import VibeWaveCore

final class ReplayGainTests: XCTestCase {
    func testStreamingLoudnessAndAlbumGate() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let loud = try LoudnessAnalyzer.analyze(makeTone(in: folder, name: "loud", amplitude: 0.1))
        let soft = try LoudnessAnalyzer.analyze(makeTone(in: folder, name: "soft", amplitude: 0.05))
        let quiet = try LoudnessAnalyzer.analyze(makeTone(in: folder, name: "quiet", amplitude: 0.0001))
        let silence = try LoudnessAnalyzer.analyze(makeTone(in: folder, name: "silence", amplitude: 0))
        let short = try LoudnessAnalyzer.analyze(makeTone(in: folder, name: "short", amplitude: 0.1, frames: 4_800))

        // Стерео синус 1 кГц с пиком −20 dBFS даёт около −20 LUFS по BS.1770.
        XCTAssertEqual(try XCTUnwrap(loud.loudness), -20, accuracy: 0.04)
        XCTAssertEqual(try XCTUnwrap(soft.gain) - XCTUnwrap(loud.gain), 6.0206, accuracy: 0.001)
        XCTAssertEqual(loud.peak, 0.1, accuracy: 0.000001)
        XCTAssertNil(quiet.gain)
        XCTAssertNil(silence.gain)
        XCTAssertNil(short.gain)
        XCTAssertEqual(short.peak, loud.peak, accuracy: 0.000001)

        let belowRelativeGate = try LoudnessAnalyzer.analyze(
            makeTone(in: folder, name: "belowRelativeGate", amplitude: 0.005)
        )
        XCTAssertNotNil(belowRelativeGate.gain)
        let album = try LoudnessAnalyzer.replayGain(for: [loud, soft, belowRelativeGate, quiet, silence])
        XCTAssertEqual(album.count, 5)
        XCTAssertEqual(album[0].trackGain, loud.gain)
        XCTAssertEqual(album[1].trackGain, soft.gain)
        XCTAssertEqual(try XCTUnwrap(album[0].albumGain), 4.04, accuracy: 0.04)
        XCTAssertEqual(album[4].albumGain, album[0].albumGain)
        XCTAssertEqual(album[1].albumPeak, loud.peak)
        XCTAssertThrowsError(try LoudnessAnalyzer.replayGain(for: [loud], isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        var polls = 0
        XCTAssertThrowsError(try LoudnessAnalyzer.analyze(makeTone(in: folder, name: "cancel", amplitude: 0.1)) {
            polls += 1
            return polls == 3
        }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testTagRoundTripPreservesOtherMetadataAndAudio() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let values = ReplayGainValues(trackGain: -6.24, albumGain: -4.53, trackPeak: 1.05, albumPeak: 1.1)
        for (name, audioOffset) in [("silence.mp3", 0), ("silence.flac", 42)] {
            let source = fixtures.appendingPathComponent(name)
            let file = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: file)
            let audio = try Data(contentsOf: source).dropFirst(audioOffset)
            var edit = AudioTagEdit()
            edit.fields[.title] = "Прежнее название"
            _ = try AudioMetadataFile.write(edit, to: file)
            edit = AudioTagEdit()
            edit.replayGain = values
            XCTAssertEqual(try AudioMetadataFile.write(edit, to: file).replayGain, values)
            XCTAssertEqual(try AudioMetadataFile.read(file).fields[.title], "Прежнее название")
            XCTAssertEqual(try Data(contentsOf: file).suffix(audio.count), audio)
            edit = AudioTagEdit()
            edit.fields[.artist] = "Новый исполнитель"
            XCTAssertEqual(try AudioMetadataFile.write(edit, to: file).replayGain, values)
            edit = AudioTagEdit()
            edit.replayGain = ReplayGainValues()
            let cleared = try AudioMetadataFile.write(edit, to: file)
            XCTAssertTrue(cleared.replayGain.isEmpty)
            XCTAssertEqual(cleared.fields[.artist], "Новый исполнитель")
            XCTAssertEqual(try Data(contentsOf: file).suffix(audio.count), audio)
        }
    }

    func testMP3ReadsSharedUTF16ByteOrderMarkAndPreservesOtherUserText() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.mp3")
        let audio = try Data(contentsOf: fixtures.appendingPathComponent("silence.mp3"))
        func userText(_ data: Data) -> Data {
            var frame = Data("TXXX".utf8)
            frame.append(contentsOf: [0, 0, 0, UInt8(data.count), 0, 0])
            frame.append(data)
            return frame
        }
        let invalid = userText(Data([0]) + Data("REPLAYGAIN_TRACK_GAIN\0nan dB".utf8))
        var utf16 = Data([1, 0xFF, 0xFE])
        utf16.append(try XCTUnwrap("replaygain_track_gain".data(using: .utf16LittleEndian)))
        utf16.append(contentsOf: [0, 0])
        utf16.append(try XCTUnwrap("-5.5 dB".data(using: .utf16LittleEndian)))
        let unrelated = userText(Data([0]) + Data("PRIVATE_KEY\0private_value".utf8))
        let frames = invalid + userText(utf16) + unrelated
        var file = Data("ID3".utf8)
        file.append(contentsOf: [3, 0, 0, 0, 0, UInt8(frames.count >> 7), UInt8(frames.count & 127)])
        file.append(frames)
        file.append(audio)
        try file.write(to: url)

        XCTAssertEqual(try AudioMetadataFile.read(url).replayGain.trackGain, -5.5)
        var edit = AudioTagEdit()
        edit.replayGain = ReplayGainValues(albumGain: -3)
        XCTAssertEqual(try AudioMetadataFile.write(edit, to: url).replayGain, edit.replayGain)
        let updated = try Data(contentsOf: url)
        XCTAssertNotNil(updated.range(of: unrelated))
        XCTAssertNil(updated.range(of: invalid))
        XCTAssertNil(updated.range(of: userText(utf16)))
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Checks/Fixtures")
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func makeTone(in folder: URL, name: String, amplitude: Double, frames: Int = 48_000) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let value = Float(amplitude * sin(2 * .pi * Double(frame % 48) / 48))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }
}
