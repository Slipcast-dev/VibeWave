import AudioToolbox
import AVFoundation
import Foundation

/// Opus и Vorbis в Ogg: собственный разбор контейнера и системный декодер пакетов
/// (`AudioConverter` из AudioToolbox; `AVAudioConverter` неверно декодирует отдельные пакеты Vorbis). Позиции звука привязываются к гранулам страниц, поэтому
/// pre-skip, начальная задержка декодера и обрезка конца не зависят от его реализации.
///
/// Opus всегда декодируется в 48 кГц (RFC 7845), усиление из OpusHead применяется к PCM.
/// Системный декодер Vorbis требует длительность каждого пакета, её даёт разбор
/// режимов блоков из setup-заголовка. При перемотке декодирование начинается раньше цели
/// (400 мс для Opus, половина длинного блока для Vorbis), лишние отсчёты отбрасываются.
public final class OggAudioSource: AudioPCMSource {
    public let processingFormat: AVAudioFormat
    public let fileFormat: AVAudioFormat
    public private(set) var length: AVAudioFramePosition = 0

    public var framePosition: AVAudioFramePosition {
        get { position }
        set { position = max(0, min(newValue, length)); positioned = false }
    }

    let codec: OggCodec
    private let reader: OggFileReader
    private let info: OggStreamInfo
    private let vorbis: VorbisBlocks?
    private let converter: AudioConverterRef
    private let input: DecoderInput
    private let decoded: AVAudioPCMBuffer
    private let gain: Float
    private let endGranule: Int64
    private let channels: Int
    private let searchSpan: UInt64
    /// Гранула первого кадра: начальное смещение потока плюс pre-skip.
    private var firstGranule: Int64 = 0

    private var cursor: OggPacketCursor
    private var position: AVAudioFramePosition = 0
    /// false — позицию задали снаружи, перед чтением её нужно сверить с готовым PCM.
    private var positioned = true

    /// Готовый PCM. `readyStart` — гранула первого непрочитанного кадра.
    private var ready: [[Float]]
    private var readyIndex = 0
    private var readyStart: Int64 = 0
    /// Декодированные пакеты, для которых ещё не встретилась гранула страницы.
    private var staging: [[Float]]
    /// Номинальная длительность пакетов в `staging` по разметке кодека.
    private var stagingNominal: Int64 = 0

    // Состояние текущего прогона декодера после сброса.
    private var anchored = false
    private var runFromStart = true
    private var runStartNominal: Int64?
    private var needsEarlierStart = false
    private var dropFirstPacket = false
    private var previousBlock: Int?
    private var streamEnded = false

    private var readyCount: Int { ready[0].count - readyIndex }
    private var readyEnd: Int64 { readyStart + Int64(readyCount) }

    public convenience init(url: URL) throws {
        try self.init(url: url, searchSpan: 128 * 1024)
    }

    /// `searchSpan` — размер участка, после которого поиск страницы переходит с деления пополам
    /// на последовательный просмотр. Проверки уменьшают его, чтобы короткие файлы проходили оба режима.
    init(url: URL, searchSpan: UInt64) throws {
        self.searchSpan = max(4096, searchSpan)
        reader = try OggFileReader(url: url)
        info = try OggStreamInfo.read(reader)
        codec = info.codec
        channels = info.channels
        vorbis = info.codec == .vorbis ? try VorbisBlocks(identification: info.headers[0], setup: info.headers[2]) : nil
        var description = AudioStreamBasicDescription(
            mSampleRate: info.sampleRate, mFormatID: info.codec == .opus ? kAudioFormatOpus : Self.vorbisFormat,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(info.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let compressed = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(standardFormatWithSampleRate: info.sampleRate,
                                         channels: AVAudioChannelCount(info.channels)),
              let decoded = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 8192) else {
            throw OggFailure.unsupportedStream
        }
        // Нет системного декодера (Vorbis на ранних macOS) — неподдерживаемый кодек:
        // ошибка OSStatus сопоставляется с сообщением так же, как у AVAudioFile.
        var made: AudioConverterRef?
        let status = AudioConverterNew(&description, output.streamDescription, &made)
        guard status == noErr, let converter = made else {
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(status == noErr ? kAudioConverterErr_FormatNotSupported : status))
        }
        if info.codec == .vorbis {
            let cookie = Self.xiphLaced(info.headers)
            let result = cookie.withUnsafeBytes {
                AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
            }
            guard result == noErr else {
                AudioConverterDispose(converter)
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
            }
        }
        self.converter = converter
        input = DecoderInput(channels: info.channels)
        self.decoded = decoded
        processingFormat = output
        fileFormat = compressed
        gain = Float(pow(10, Double(info.outputGain) / (20 * 256)))
        ready = Array(repeating: [], count: info.channels)
        staging = ready
        cursor = OggPacketCursor(serial: info.serial, offset: info.dataOffset, resynchronized: false)
        endGranule = info.lastGranule
        restart(at: info.dataOffset)
        try fillReady()
        firstGranule = max(0, runStartNominal ?? 0) + info.preSkip
        length = max(0, endGranule - firstGranule)
    }

    deinit { AudioConverterDispose(converter) }

    public func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        let wanted = min(Int64(frameCount), Int64(buffer.frameCapacity), length - position)
        guard wanted > 0, let output = buffer.floatChannelData,
              Int(buffer.format.channelCount) == channels else { return }
        if !positioned { try locate(firstGranule + position) }
        positioned = true
        var copied: Int64 = 0
        while copied < wanted {
            let target = firstGranule + position
            if readyEnd <= target {
                discardReady()
                guard try fillReady() else { break }
                continue
            }
            if readyStart < target { consume(Int(target - readyStart)); continue }
            let count = Int(min(wanted - copied, readyEnd - target))
            for channel in 0..<channels {
                ready[channel].withUnsafeBufferPointer { source in
                    (output[channel] + Int(copied)).update(from: source.baseAddress! + readyIndex, count: count)
                }
            }
            consume(count)
            copied += Int64(count)
            position += Int64(count)
        }
        // Декодер вернул меньше кадров, чем обещают гранулы: недостающее заполняется
        // тишиной, чтобы длина источника оставалась точной для расписания и переходов.
        if copied < wanted {
            let missing = Int(wanted - copied)
            for channel in 0..<channels { (output[channel] + Int(copied)).initialize(repeating: 0, count: missing) }
            position += Int64(missing)
            copied = wanted
        }
        buffer.frameLength = AVAudioFrameCount(copied)
    }

    // MARK: Перемотка

    /// Короткий шаг вперёд дочитывается декодером, дальний переход ищет страницу.
    private func locate(_ target: Int64) throws {
        if anchored, readyStart <= target, target < readyEnd + Int64(info.sampleRate) * 2 { return }
        // RFC 7845 требует не меньше 80 мс; на сложном сигнале CELT сходится к непрерывному
        // декодированию дольше, поэтому для Opus берём 400 мс. Vorbis точен после одного окна.
        var preroll: Int64 = codec == .opus ? 19_200 : Int64(vorbis?.longBlock ?? 8192) / 2
        while true {
            let offset = try pageOffset(before: target - preroll)
            restart(at: offset)
            try fillReady()
            if offset == info.dataOffset { return }
            if !needsEarlierStart && (readyCount == 0 || readyStart <= target) { return }
            preroll *= 4
        }
    }

    /// Смещение страницы, следующей за последней страницей с гранулой не больше `limit`.
    private func pageOffset(before limit: Int64) throws -> UInt64 {
        var low = info.dataOffset, high = reader.size, best = info.dataOffset
        while high > low + searchSpan {
            let middle = low + (high - low) / 2
            guard let page = try granulePage(from: middle, limit: high), page.granule <= limit else {
                high = middle
                continue
            }
            best = page.end
            low = page.end
        }
        var offset = low
        while let page = try granulePage(from: offset, limit: reader.size), page.granule <= limit {
            best = page.end
            offset = page.end
        }
        return best
    }

    private func granulePage(from offset: UInt64, limit: UInt64) throws -> OggPage? {
        var position = offset
        while let page = try reader.nextValidPage(from: position, limit: limit) {
            if page.serial == info.serial && page.hasGranule { return page }
            position = page.end
        }
        return nil
    }

    // MARK: Декодирование

    private func restart(at offset: UInt64) {
        cursor = OggPacketCursor(serial: info.serial, offset: offset, resynchronized: offset != info.dataOffset)
        AudioConverterReset(converter)
        anchored = false
        runFromStart = offset == info.dataOffset
        runStartNominal = nil
        needsEarlierStart = false
        // Первый пакет Vorbis после сброса не имеет предыдущего окна (в libvorbis — 0 кадров).
        dropFirstPacket = codec == .vorbis
        previousBlock = nil
        streamEnded = false
        stagingNominal = 0
        for channel in 0..<channels {
            ready[channel].removeAll(keepingCapacity: true)
            staging[channel].removeAll(keepingCapacity: true)
        }
        readyIndex = 0
        readyStart = 0
    }

    /// Декодирует пакеты до ближайшей гранулы. false — поток закончился или прогон начат слишком поздно.
    @discardableResult
    private func fillReady() throws -> Bool {
        while !streamEnded && !needsEarlierStart {
            guard let packet = try cursor.next(reader) else {
                streamEnded = true
                try drain()
                appendStaging(anchor: nil, finalPage: true)
                break
            }
            try decode(packet.data)
            if packet.endsStream {
                streamEnded = true
                // Задержанные декодером кадры относятся к концу потока.
                try drain()
                appendStaging(anchor: packet.granule, finalPage: true)
            } else if let granule = packet.granule {
                appendStaging(anchor: granule, finalPage: false)
            }
            if readyCount > 0 { return true }
        }
        return readyCount > 0 && !needsEarlierStart
    }

    /// Первая гранула прогона задаёт позицию PCM назад от конца страницы.
    /// Гранула последней страницы учитывает обрезку конца, поэтому по ней позиция не задаётся:
    /// такой прогон допустим только от начала потока, иначе перемотка начинается раньше.
    private func appendStaging(anchor: Int64?, finalPage: Bool) {
        let count = staging[0].count
        defer {
            stagingNominal = 0
            for channel in 0..<channels { staging[channel].removeAll(keepingCapacity: true) }
        }
        guard count > 0 || !anchored else { return }
        if !anchored {
            if let anchor = anchor, !finalPage {
                readyStart = anchor - Int64(count)
                runStartNominal = anchor - stagingNominal
            } else if runFromStart {
                readyStart = stagingNominal - Int64(count)
                runStartNominal = 0
            } else {
                needsEarlierStart = true
                return
            }
            anchored = true
        } else if let anchor = anchor, !finalPage, readyEnd + Int64(count) != anchor {
            // Расхождение счёта кадров с гранулой: позиции следуют грануле.
            readyStart += anchor - (readyEnd + Int64(count))
        }
        var keep = count
        let end = readyEnd + Int64(count)
        if end > endGranule { keep = max(0, count - Int(end - endGranule)) }
        guard keep > 0 else { return }
        for channel in 0..<channels { ready[channel].append(contentsOf: staging[channel].prefix(keep)) }
    }

    private func decode(_ packet: Data) throws {
        guard !packet.isEmpty else { return }
        let frames: Int
        switch codec {
        case .opus:
            guard let value = Self.opusFrames(packet) else { throw OggFailure.damaged }
            frames = value
        case .vorbis:
            guard let current = vorbis?.blockSize(of: packet) else { throw OggFailure.damaged }
            let previous = previousBlock ?? current
            previousBlock = current
            frames = previous / 4 + current / 4
        }
        input.load(packet, frames: frames)
        let keep = !dropFirstPacket
        dropFirstPacket = false
        if keep { stagingNominal += Int64(frames) }
        try convert(keep: keep)
    }

    /// Выдаёт кадры, задержанные декодером, в конце потока.
    private func drain() throws {
        input.finish()
        try convert(keep: true)
    }

    /// Декодирует выданный пакет: функция ввода отдаёт его один раз, затем сообщает
    /// «данных пока нет», и конвертер возвращает всё, что получилось из этого пакета.
    private func convert(keep: Bool) throws {
        let capacity = decoded.frameCapacity
        while true {
            // Каждое обращение к mutableAudioBufferList сбрасывает размеры по frameLength.
            let list = decoded.mutableAudioBufferList
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for index in buffers.indices { buffers[index].mDataByteSize = capacity * 4 }
            var frames = capacity
            let status = AudioConverterFillComplexBuffer(converter, DecoderInput.provide,
                                                         Unmanaged.passUnretained(input).toOpaque(),
                                                         &frames, list, nil)
            guard status == noErr || status == DecoderInput.noDataNow else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            let count = Int(frames)
            if count > 0, keep, let samples = decoded.floatChannelData {
                for channel in 0..<channels {
                    let pointer = UnsafeBufferPointer(start: samples[channel], count: count)
                    if gain == 1 { staging[channel].append(contentsOf: pointer) }
                    else { staging[channel].append(contentsOf: pointer.lazy.map { $0 * self.gain }) }
                }
            }
            if frames < capacity || count == 0 { break }
        }
    }

    private func consume(_ count: Int) {
        readyIndex += count
        readyStart += Int64(count)
        if readyIndex > 65_536 && readyIndex * 2 > ready[0].count {
            for channel in 0..<channels { ready[channel].removeFirst(readyIndex) }
            readyIndex = 0
        }
    }

    private func discardReady() {
        readyStart = readyEnd
        for channel in 0..<channels { ready[channel].removeAll(keepingCapacity: true) }
        readyIndex = 0
    }

    // MARK: Разметка кодеков

    static let vorbisFormat: AudioFormatID = 0x766F_7262 // 'vorb'

    /// Magic cookie декодера Vorbis: три заголовка в Xiph-укладке, как в CodecPrivate Matroska.
    static func xiphLaced(_ headers: [Data]) -> Data {
        var cookie = Data([UInt8(headers.count - 1)])
        for header in headers.dropLast() {
            var size = header.count
            while size >= 255 { cookie.append(255); size -= 255 }
            cookie.append(UInt8(size))
        }
        for header in headers { cookie.append(header) }
        return cookie
    }

    /// Длительность пакета Opus в кадрах 48 кГц по байту TOC (RFC 6716, раздел 3.1).
    static func opusFrames(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frameSize: Int
        switch config {
        case 0..<12: frameSize = [480, 960, 1920, 2880][config % 4]
        case 12..<16: frameSize = [480, 960][config % 2]
        default: frameSize = [120, 240, 480, 960][config % 4]
        }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count > 1 else { return nil }
            count = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        let total = count * frameSize
        return (1...5760).contains(total) ? total : nil
    }
}

/// Пакет для функции ввода `AudioConverterFillComplexBuffer`. Память пакета живёт до следующего пакета.
private final class DecoderInput {
    static let noDataNow: OSStatus = 0x6E6F_6474 // 'nodt'

    private var storage = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 16)
    private var capacity = 1
    private var description = AudioStreamPacketDescription()
    private var pending = false
    private var ended = false
    private let channels: UInt32

    init(channels: Int) { self.channels = UInt32(channels) }

    deinit { storage.deallocate() }

    func load(_ packet: Data, frames: Int) {
        if packet.count > capacity {
            storage.deallocate()
            capacity = packet.count
            storage = .allocate(byteCount: capacity, alignment: 16)
        }
        packet.withUnsafeBytes { storage.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(frames),
                                                   mDataByteSize: UInt32(packet.count))
        pending = true
        ended = false
    }

    func finish() {
        pending = false
        ended = true
    }

    static let provide: AudioConverterComplexInputDataProc = { _, count, data, descriptions, context in
        let input = Unmanaged<DecoderInput>.fromOpaque(context!).takeUnretainedValue()
        guard input.pending else {
            count.pointee = 0
            data.pointee.mBuffers.mData = nil
            data.pointee.mBuffers.mDataByteSize = 0
            // Ноль пакетов без ошибки — конец потока: декодер отдаёт задержанные кадры.
            return input.ended ? noErr : noDataNow
        }
        input.pending = false
        count.pointee = 1
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mData = input.storage
        data.pointee.mBuffers.mDataByteSize = input.description.mDataByteSize
        data.pointee.mBuffers.mNumberChannels = input.channels
        withUnsafeMutablePointer(to: &input.description) { descriptions?.pointee = $0 }
        return noErr
    }
}

/// Размеры блоков Vorbis I: два размера из заголовка идентификации и флаг блока
/// каждого режима из конца setup-заголовка. Режимы читаются с конца, как в разборщиках
/// FFmpeg и libvorbisfile: полный разбор кодовых книг для длительности пакета не нужен.
struct VorbisBlocks {
    let shortBlock: Int
    let longBlock: Int
    let longModes: [Bool]
    private let modeBits: Int

    init(identification: Data, setup: Data) throws {
        guard identification.count >= 30 else { throw OggFailure.damaged }
        let sizes = identification[identification.startIndex + 28]
        shortBlock = 1 << Int(sizes & 0x0F)
        longBlock = 1 << Int(sizes >> 4)
        guard (64...8192).contains(shortBlock), (shortBlock...8192).contains(longBlock) else { throw OggFailure.damaged }
        guard let modes = Self.modes(setup) else { throw OggFailure.damaged }
        longModes = modes
        modeBits = Self.bitWidth(modes.count - 1)
    }

    /// Размер блока аудиопакета: бит типа 0, затем номер режима (биты от младшего).
    func blockSize(of packet: Data) -> Int? {
        guard let first = packet.first, first & 1 == 0 else { return nil }
        var mode = 0
        for bit in 0..<modeBits {
            let index = 1 + bit
            guard index / 8 < packet.count else { return nil }
            let byte = packet[packet.startIndex + index / 8]
            mode |= Int((byte >> UInt8(index % 8)) & 1) << bit
        }
        guard mode < longModes.count else { return nil }
        return longModes[mode] ? longBlock : shortBlock
    }

    static func bitWidth(_ value: Int) -> Int {
        var width = 0, rest = value
        while rest > 0 { width += 1; rest >>= 1 }
        return width
    }

    /// В обратном порядке бит каждое поле читается от старшего бита, поэтому значение
    /// совпадает с прямым чтением. Хвост: …, mode_count−1 (6), режимы по 41 биту, бит кадрирования.
    static func modes(_ setup: Data) -> [Bool]? {
        let bytes = [UInt8](setup.reversed())
        let total = bytes.count * 8
        func bit(_ index: Int) -> Int { Int(bytes[index / 8] >> UInt8(7 - index % 8)) & 1 }
        func bits(_ index: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 << 1 | bit(index + $1) } }
        var framing = 0
        while framing < total && bit(framing) == 0 { framing += 1 }
        guard framing < total else { return nil }
        let start = framing + 1
        var position = start, count = 0, found = 0
        while total - position >= 97 {
            let mapping = bits(position, 8), transform = bits(position + 8, 16), window = bits(position + 24, 16)
            guard mapping <= 63, transform == 0, window == 0 else { break }
            position += 41
            count += 1
            if count > 64 { break }
            if bits(position, 6) + 1 == count { found = count }
        }
        guard found > 0 else { return nil }
        var flags = [Bool](repeating: false, count: found)
        position = start
        for index in (0..<found).reversed() {
            position += 40
            flags[index] = bit(position) == 1
            position += 1
        }
        return flags
    }
}
