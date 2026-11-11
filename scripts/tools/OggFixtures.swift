// Генератор фикстур Ogg для Checks/FormatFixtures. Приложение и проверки его не используют.
//
//   swift scripts/tools/OggFixtures.swift sweep <out.wav> <секунды>
//       Стереосвип 100 Гц → 8 кГц, 48 кГц, PCM 16 бит.
//   swift scripts/tools/OggFixtures.swift opus <in.caf> <out.opus> <пакетов на страницу> [КЛЮЧ=значение ...]
//       Перекладывает пакеты Opus из CAF в Ogg (RFC 7845) без перекодирования:
//       pre-skip и обрезка конца берутся из таблицы пакетов CAF.
//
// Штатная запись Ogg в AudioToolbox на проверенных системах отказывает ('fmt?'),
// кодировщика Vorbis в macOS нет; Vorbis кодируется oggenc (vorbis-tools), см. docs/TESTING.md.
import AudioToolbox
import AVFoundation
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

let crcTable: [UInt32] = (0..<256).map { index in
    var value = UInt32(index) << 24
    for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
    return value
}

struct OggWriter {
    let serial: UInt32
    var sequence: UInt32 = 0
    var output: [UInt8] = []

    mutating func page(_ packets: [[UInt8]], granule: Int64, flags: UInt8, continuesLast: Bool = false) {
        var lacing: [UInt8] = []
        var body: [UInt8] = []
        for (index, packet) in packets.enumerated() {
            var size = packet.count
            while size >= 255 { lacing.append(255); size -= 255 }
            if !(continuesLast && index == packets.count - 1) { lacing.append(UInt8(size)) }
            body += packet
        }
        precondition(lacing.count <= 255, "Слишком много сегментов на странице")
        var page = Array("OggS".utf8) + [0, flags] + littleEndian(granule) + littleEndian(serial) +
            littleEndian(sequence) + [0, 0, 0, 0] + [UInt8(lacing.count)] + lacing + body
        sequence += 1
        var crc: UInt32 = 0
        for byte in page { crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)] }
        page.replaceSubrange(22..<26, with: littleEndian(crc))
        output += page
    }
}

func sweep(_ path: String, seconds: Double) throws {
    let rate = 48_000.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    // Экспоненциальный свип: каждая позиция имеет свою частоту, сдвиг сразу заметен.
    let start = 100.0, end = 8_000.0, k = log(end / start) / seconds
    for frame in 0..<Int(frames) {
        let time = Double(frame) / rate
        let phase = 2 * Double.pi * start * (exp(k * time) - 1) / k
        buffer.floatChannelData![0][frame] = Float(0.4 * sin(phase))
        buffer.floatChannelData![1][frame] = Float(0.3 * sin(phase * 1.5))
    }
    try file.write(from: buffer)
}

func opus(_ input: String, _ outputPath: String, perPage: Int, tags: [String]) {
    var file: AudioFileID?
    guard AudioFileOpenURL(URL(fileURLWithPath: input) as CFURL, .readPermission, 0, &file) == noErr, let file = file else {
        fail("Не открыт \(input)")
    }
    var description = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout.size(ofValue: description))
    AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &description)
    guard description.mFormatID == kAudioFormatOpus, description.mChannelsPerFrame <= 2 else { fail("Нужен CAF с Opus 1–2 канала") }
    var table = AudioFilePacketTableInfo()
    size = UInt32(MemoryLayout.size(ofValue: table))
    guard AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr else { fail("Нет таблицы пакетов") }
    var count: UInt64 = 0
    size = 8
    AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &count)
    var maximum: UInt32 = 0
    size = 4
    AudioFileGetProperty(file, kAudioFilePropertyMaximumPacketSize, &size, &maximum)
    var data = [UInt8](repeating: 0, count: Int(maximum) * Int(count))
    var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: Int(count))
    var bytes = UInt32(data.count), packets = UInt32(count)
    guard AudioFileReadPacketData(file, false, &bytes, &descriptions, 0, &packets, &data) == noErr else { fail("Пакеты не прочитаны") }
    AudioFileClose(file)
    let payloads = (0..<Int(packets)).map {
        Array(data[Int(descriptions[$0].mStartOffset)..<Int(descriptions[$0].mStartOffset) + Int(descriptions[$0].mDataByteSize)])
    }
    let frames = Int64(description.mFramesPerPacket)
    let preSkip = UInt16(table.mPrimingFrames)
    let head = Array("OpusHead".utf8) + [1, UInt8(description.mChannelsPerFrame)] + littleEndian(preSkip) +
        littleEndian(UInt32(description.mSampleRate)) + littleEndian(Int16(0)) + [0]
    var comment = Array("OpusTags".utf8) + littleEndian(UInt32(8)) + Array("VibeWave".utf8) + littleEndian(UInt32(tags.count))
    for tag in tags { comment += littleEndian(UInt32(tag.utf8.count)) + Array(tag.utf8) }
    var writer = OggWriter(serial: 0x5642_5745)
    writer.page([head], granule: 0, flags: 2)
    writer.page([comment], granule: 0, flags: 0)
    let end = Int64(preSkip) + table.mNumberValidFrames
    var index = 0
    while index < payloads.count {
        let chunk = Array(payloads[index..<min(index + perPage, payloads.count)])
        index += chunk.count
        let last = index == payloads.count
        writer.page(chunk, granule: last ? end : Int64(index) * frames, flags: last ? 4 : 0)
    }
    do { try Data(writer.output).write(to: URL(fileURLWithPath: outputPath)) } catch { fail("\(error)") }
    print("\(outputPath): \(payloads.count) пакетов, pre-skip \(preSkip), \(table.mNumberValidFrames) кадров")
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "sweep" where arguments.count == 4:
    do { try sweep(arguments[2], seconds: Double(arguments[3]) ?? 0) } catch { fail("\(error)") }
case "opus" where arguments.count >= 5:
    opus(arguments[2], arguments[3], perPage: max(1, Int(arguments[4]) ?? 1), tags: Array(arguments.dropFirst(5)))
default:
    fail("Использование: OggFixtures.swift sweep <out.wav> <секунды> | opus <in.caf> <out> <пакетов на страницу> [КЛЮЧ=значение ...]")
}
