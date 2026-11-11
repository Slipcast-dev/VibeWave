import Foundation

/// Разбор контейнера Ogg (RFC 3533) без сторонних библиотек.
/// Используется первый логический поток Opus или Vorbis. Остальные мультиплексированные
/// потоки пропускаются, у цепочки (chained Ogg) читается только первое звено.
public enum OggFailure: Error, Equatable {
    /// Нет страниц Ogg или нет потока Opus/Vorbis.
    case notOgg
    /// Нарушена структура: контрольная сумма, заголовки кодека, длина пакета.
    case damaged
    /// Поток распознан, но этот вариант не поддерживается (например, многоканальный Opus).
    case unsupportedStream
}

enum OggCodec: Equatable {
    case opus, vorbis
}

struct OggPage {
    static let headerSize = 27
    static let maximumSize = 27 + 255 + 255 * 255

    let offset: UInt64
    let size: Int
    let flags: UInt8
    let granule: Int64
    let serial: UInt32
    let lacing: [UInt8]
    let body: Data

    var continued: Bool { flags & 1 != 0 }
    var beginsStream: Bool { flags & 2 != 0 }
    var endsStream: Bool { flags & 4 != 0 }
    var end: UInt64 { offset + UInt64(size) }
    /// −1 означает, что на странице не завершается ни один пакет.
    var hasGranule: Bool { granule != -1 }
}

/// Чтение файла с окном упреждающего чтения: страницы Ogg короткие,
/// а системный вызов на каждый заголовок замедлил бы декодирование и поиск.
final class OggFileReader {
    private let handle: FileHandle
    let size: UInt64
    private var window = Data()
    private var windowStart: UInt64 = 0
    private static let windowSize = 256 * 1024

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    /// Возвращает до `count` байтов начиная с `offset`; меньше — только у конца файла.
    func bytes(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let available = Int(min(UInt64(count), size - offset))
        let windowEnd = windowStart + UInt64(window.count)
        if offset < windowStart || offset + UInt64(available) > windowEnd {
            try handle.seek(toOffset: offset)
            window = try handle.read(upToCount: max(Self.windowSize, available)) ?? Data()
            windowStart = offset
            guard window.count >= available else { throw OggFailure.damaged }
        }
        let start = Int(offset - windowStart)
        return window.subdata(in: start..<start + available)
    }

    /// Страница в точной позиции. nil — конец файла, оборванная последняя страница
    /// или чужие данные (не «OggS»).
    func page(at offset: UInt64) throws -> OggPage? {
        let header = try bytes(at: offset, count: OggPage.headerSize)
        guard header.count == OggPage.headerSize, header.starts(with: OggPage.capture) else { return nil }
        guard header[header.startIndex + 4] == 0 else { throw OggFailure.damaged }
        let segments = Int(header[header.startIndex + 26])
        let lacingData = try bytes(at: offset + UInt64(OggPage.headerSize), count: segments)
        guard lacingData.count == segments else { return nil }
        let lacing = [UInt8](lacingData)
        let bodySize = lacing.reduce(0) { $0 + Int($1) }
        let headerSize = OggPage.headerSize + segments
        let body = try bytes(at: offset + UInt64(headerSize), count: bodySize)
        guard body.count == bodySize else { return nil }
        var checked = header + lacingData + body
        let stored = checked.littleEndianInteger(at: 22, bytes: 4)
        checked.replaceSubrange(checked.startIndex + 22..<checked.startIndex + 26, with: [0, 0, 0, 0])
        guard UInt32(stored) == OggCRC.checksum(checked) else { throw OggFailure.damaged }
        return OggPage(offset: offset, size: headerSize + bodySize, flags: header[header.startIndex + 5],
                       granule: Int64(bitPattern: UInt64(header.littleEndianInteger(at: 6, bytes: 8))),
                       serial: UInt32(header.littleEndianInteger(at: 14, bytes: 4)), lacing: lacing, body: body)
    }

    /// Первая корректная страница, начинающаяся не раньше `offset` и до `limit`.
    /// Ложные совпадения «OggS» внутри сжатых данных отсекает контрольная сумма.
    func nextValidPage(from offset: UInt64, limit: UInt64) throws -> OggPage? {
        var position = offset
        let end = min(limit, size)
        while position < end {
            let chunk = try bytes(at: position, count: 64 * 1024)
            guard chunk.count >= 4 else { return nil }
            var index = chunk.startIndex
            while index + 4 <= chunk.endIndex {
                if chunk[index] == 0x4F, chunk[index + 1] == 0x67, chunk[index + 2] == 0x67, chunk[index + 3] == 0x53 {
                    let candidate = position + UInt64(index - chunk.startIndex)
                    if candidate >= end { return nil }
                    if let page = try? page(at: candidate) { return page }
                }
                index += 1
            }
            position += UInt64(max(1, chunk.count - 3))
        }
        return nil
    }
}

/// Последовательная сборка пакетов одного логического потока.
struct OggPacketCursor {
    struct Packet {
        let data: Data
        /// Гранула страницы, на которой завершился этот пакет, если он последний на ней.
        let granule: Int64?
        let endsStream: Bool
    }

    static let maximumPacket = 32 * 1024 * 1024

    let serial: UInt32
    private(set) var offset: UInt64
    private var partial: Data?
    /// После перехода в середину потока первый продолженный фрагмент отбрасывается.
    private var skipContinuation: Bool
    private var ready: [Packet] = []
    private(set) var finished = false

    init(serial: UInt32, offset: UInt64, resynchronized: Bool) {
        self.serial = serial
        self.offset = offset
        skipContinuation = resynchronized
    }

    mutating func next(_ reader: OggFileReader) throws -> Packet? {
        while ready.isEmpty {
            guard !finished else { return nil }
            guard let page = try reader.page(at: offset) else {
                // Конец файла без страницы EOS (обрезанная запись): играем то, что есть.
                // Посторонние данные, за которыми снова идут страницы, — повреждение.
                finished = true
                if offset < reader.size, try reader.nextValidPage(from: offset + 1, limit: reader.size) != nil {
                    throw OggFailure.damaged
                }
                return nil
            }
            offset = page.end
            guard page.serial == serial else { continue }
            try consume(page)
            if page.endsStream { finished = true }
        }
        return ready.removeFirst()
    }

    private mutating func consume(_ page: OggPage) throws {
        var start = page.body.startIndex
        var completed: [Data] = []
        var discarding = false
        if page.continued {
            if partial == nil {
                discarding = skipContinuation
                if !discarding { throw OggFailure.damaged }
            }
        } else if partial != nil {
            // Пакет оборвался без продолжения.
            throw OggFailure.damaged
        }
        skipContinuation = false
        var current = discarding ? nil : partial
        partial = nil
        var length = 0
        for value in page.lacing {
            length += Int(value)
            guard value < 255 else { continue }
            let piece = page.body[start..<start + length]
            if discarding {
                discarding = false
            } else {
                var packet = current ?? Data()
                packet.append(piece)
                completed.append(packet)
            }
            current = nil
            start += length
            length = 0
        }
        if length > 0 || page.lacing.last == 255 {
            if !discarding {
                var packet = current ?? Data()
                packet.append(page.body[start..<start + length])
                guard packet.count <= Self.maximumPacket else { throw OggFailure.damaged }
                partial = packet
            } else {
                // Продолженный фрагмент не завершился и на этой странице.
                skipContinuation = true
            }
        }
        for (index, data) in completed.enumerated() {
            let last = index == completed.count - 1
            ready.append(Packet(data: data, granule: last && page.hasGranule ? page.granule : nil,
                                endsStream: last && page.endsStream && partial == nil))
        }
    }
}

/// Заголовки первого потока Opus или Vorbis и границы его данных.
struct OggStreamInfo {
    let codec: OggCodec
    let serial: UInt32
    let channels: Int
    let sampleRate: Double
    /// Opus: pre-skip из OpusHead. Vorbis: 0.
    let preSkip: Int64
    /// Opus: усиление выхода Q7.8 дБ.
    let outputGain: Int
    let headers: [Data]
    /// Смещение первой страницы со звуком (заголовки кодека завершаются на отдельной странице).
    let dataOffset: UInt64
    let lastGranule: Int64

    static func read(_ reader: OggFileReader) throws -> OggStreamInfo {
        // Начальные страницы BOS идут подряд. Ищем первый поток Opus/Vorbis.
        var offset: UInt64 = 0
        var chosen: (OggCodec, UInt32)?
        while chosen == nil {
            guard let page = try reader.page(at: offset) else { throw OggFailure.notOgg }
            guard page.beginsStream else { break }
            if page.body.starts(with: Data("OpusHead".utf8)) { chosen = (.opus, page.serial) }
            else if page.body.starts(with: Data([1] + Array("vorbis".utf8))) { chosen = (.vorbis, page.serial) }
            offset = page.end
        }
        guard let (codec, serial) = chosen else { throw OggFailure.notOgg }
        var cursor = OggPacketCursor(serial: serial, offset: 0, resynchronized: false)
        var headers: [Data] = []
        let count = codec == .opus ? 2 : 3
        while headers.count < count {
            guard let packet = try cursor.next(reader) else { throw OggFailure.damaged }
            headers.append(packet.data)
        }
        let dataOffset = cursor.offset
        var channels = 0, rate = 0.0, preSkip: Int64 = 0, gain = 0
        switch codec {
        case .opus:
            var head = TagByteReader(headers[0])
            _ = try head.read(8)
            let version = try head.integer(1)
            channels = try head.integer(1)
            preSkip = Int64(try head.integer(2, littleEndian: true))
            _ = try head.integer(4, littleEndian: true)
            let rawGain = try head.integer(2, littleEndian: true)
            gain = rawGain >= 0x8000 ? rawGain - 0x10000 : rawGain
            let family = try head.integer(1)
            guard version & 0xF0 == 0, channels > 0 else { throw OggFailure.damaged }
            guard family == 0 && channels <= 2 else { throw OggFailure.unsupportedStream }
            guard headers[1].starts(with: Data("OpusTags".utf8)) else { throw OggFailure.damaged }
            rate = 48_000
        case .vorbis:
            var head = TagByteReader(headers[0])
            _ = try head.read(7)
            let version = try head.integer(4, littleEndian: true)
            channels = try head.integer(1)
            rate = Double(try head.integer(4, littleEndian: true))
            guard version == 0, channels > 0, rate > 0,
                  headers[1].starts(with: Data([3] + Array("vorbis".utf8))),
                  headers[2].starts(with: Data([5] + Array("vorbis".utf8))) else { throw OggFailure.damaged }
            // Порядок каналов Vorbis для 3+ каналов отличается от Core Audio: пока только моно и стерео.
            guard channels <= 2 else { throw OggFailure.unsupportedStream }
        }
        let last = try lastGranule(reader, serial: serial, after: dataOffset)
        return OggStreamInfo(codec: codec, serial: serial, channels: channels, sampleRate: rate, preSkip: preSkip,
                             outputGain: gain, headers: headers, dataOffset: dataOffset, lastGranule: last)
    }

    /// Последняя гранула потока: ищем страницы с конца файла окнами нарастающего размера.
    private static func lastGranule(_ reader: OggFileReader, serial: UInt32, after start: UInt64) throws -> Int64 {
        var span: UInt64 = 64 * 1024
        var end = reader.size
        while end > start {
            let from = end > start + span ? end - span : start
            var position = from
            var found: Int64?
            while let page = try reader.nextValidPage(from: position, limit: end) {
                if page.serial == serial && page.hasGranule { found = page.granule }
                position = page.end
            }
            if let found = found { return found }
            end = from
            span = min(span * 4, 16 * 1024 * 1024)
        }
        throw OggFailure.damaged
    }
}

enum OggCRC {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data { crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)] }
        return crc
    }
}

extension OggPage {
    static let capture = Data("OggS".utf8)
}

extension Data {
    func littleEndianInteger(at position: Int, bytes: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<bytes).reversed() { value = value << 8 | UInt64(self[startIndex + position + index]) }
        return value
    }
}
