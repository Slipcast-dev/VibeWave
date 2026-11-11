import Foundation

/// Теги Ogg только для чтения: Vorbis Comment из OpusTags или из второго заголовка Vorbis.
/// Обложка — METADATA_BLOCK_PICTURE (base64 блока PICTURE FLAC).
/// Для Opus громкость задают R128_TRACK_GAIN/R128_ALBUM_GAIN (Q7.8 дБ к −23 LUFS после
/// усиления заголовка); в шкалу ReplayGain с целью −18 LUFS они переводятся сдвигом +5 дБ.
enum OggTag {
    static func read(_ url: URL, includeArtwork: Bool) throws -> AudioMetadata {
        let reader = try OggFileReader(url: url)
        let info: OggStreamInfo
        do { info = try OggStreamInfo.read(reader) } catch { throw AudioMetadataFile.Failure.damaged }
        let packet = info.headers[1]
        let prefix = info.codec == .opus ? 8 : 7
        guard packet.count >= prefix else { throw AudioMetadataFile.Failure.damaged }
        // У Vorbis после комментариев идёт бит кадрирования, у Opus могут следовать двоичные данные.
        let comment = try VorbisComment(lenient: packet.dropFirst(prefix))
        return metadata(comment, codec: info.codec, includeArtwork: includeArtwork)
    }

    static func metadata(_ comment: VorbisComment, codec: OggCodec, includeArtwork: Bool) -> AudioMetadata {
        var result = AudioMetadata()
        var loudness = ReplayGainValues()
        var cover: AudioArtwork?
        var firstPicture: AudioArtwork?
        for value in comment.values {
            guard let (key, text) = VorbisComment.split(value) else { continue }
            if let field = VorbisComment.field(for: key), result.fields[field] == nil { result.fields[field] = text }
            result.replayGain.readTag(key, value: text)
            if codec == .opus { readR128(key, text, into: &loudness) }
            if includeArtwork, key == "METADATA_BLOCK_PICTURE", cover == nil,
               text.utf8.count <= AudioArtwork.maximumSize * 4 / 3 + 4,
               let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
               let (type, artwork) = try? FLACTag.picture(data) {
                if type == 3 { cover = artwork } else if firstPicture == nil { firstPicture = artwork }
            }
        }
        if codec == .opus {
            // R128 — штатный для Opus способ; REPLAYGAIN_* остаются запасным вариантом.
            if let gain = loudness.trackGain { result.replayGain.trackGain = gain }
            if let gain = loudness.albumGain { result.replayGain.albumGain = gain }
        }
        result.artwork = cover ?? firstPicture
        return result
    }

    private static func readR128(_ key: String, _ text: String, into values: inout ReplayGainValues) {
        let tag: ReplayGainValues.Tag
        switch key {
        case "R128_TRACK_GAIN": tag = .trackGain
        case "R128_ALBUM_GAIN": tag = .albumGain
        default: return
        }
        guard values[tag] == nil, let raw = Int(text.trimmingCharacters(in: .whitespaces)),
              (-32768...32767).contains(raw) else { return }
        values[tag] = Double(raw) / 256 + 5
    }
}

extension VorbisComment {
    /// Разбор без требования закончиться ровно на последнем комментарии.
    init(lenient data: Data) throws {
        var reader = TagByteReader(Data(data))
        let vendor = try reader.lengthPrefixed(littleEndian: true)
        let count = try reader.integer(4, littleEndian: true)
        guard count <= reader.remaining / 4 else { throw AudioMetadataFile.Failure.damaged }
        var values: [Data] = []
        for _ in 0..<count { values.append(try reader.lengthPrefixed(littleEndian: true)) }
        self.init(vendor: vendor, values: values)
    }
}
