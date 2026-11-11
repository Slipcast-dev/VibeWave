import AVFoundation
import Foundation
import VibeWaveCore

struct AudioStreamItem: Equatable, Sendable {
    let track: Track
    let cachedGain: ReplayGainValues?
}

struct AudioStreamPlan: Equatable, Sendable {
    let current: AudioStreamItem
    let upcoming: [AudioStreamItem]
    let options: AudioPlaybackOptions
    let equalizer: EqualizerSettings
}

struct AudioStreamBoundary: Sendable {
    let item: AudioStreamItem
    let url: URL
    let info: AudioEngine.Info
    let consumed: AVAudioFramePosition
    let ordinal: Int
}

/// Поставщик коротких PCM-буферов для `AudioEngine`. `produce` вызывается
/// только на последовательной очереди декодирования.
protocol AudioChunkProducer: AnyObject, Sendable {
    func produce(maximum: Int) throws -> (chunks: [AudioTransitionStream.Chunk], done: Bool)
}

/// Подача одного источника без переходов: для форматов, которые нельзя передать
/// в `scheduleSegment` (Ogg). Громкость ReplayGain при этом задаёт узел нормализации.
/// Позиция выставляется на очереди декодирования, где источник и читается.
final class AudioSourceFeeder: AudioChunkProducer, @unchecked Sendable {
    private let source: AudioPCMSource
    private let start: AVAudioFramePosition
    private var positioned = false

    init(source: AudioPCMSource, start: AVAudioFramePosition) {
        self.source = source
        self.start = start
    }

    func produce(maximum: Int) throws -> (chunks: [AudioTransitionStream.Chunk], done: Bool) {
        if !positioned {
            source.framePosition = start
            positioned = true
        }
        var chunks: [AudioTransitionStream.Chunk] = []
        while chunks.count < maximum {
            let remaining = source.length - source.framePosition
            guard remaining > 0 else { return (chunks, true) }
            let frames = AVAudioFrameCount(min(4096, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else {
                throw AudioDecoding.Failure.invalidAudio
            }
            try source.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { return (chunks, true) }
            chunks.append(AudioTransitionStream.Chunk(buffer: buffer, boundary: nil))
        }
        return (chunks, source.framePosition >= source.length)
    }
}

/// Декодирование выполняется на выделенной последовательной очереди.
/// В граф передаются короткие Float32-буферы одного формата.
///
/// `@unchecked Sendable` оправдан инвариантом, который компилятор проверить не может:
/// источник PCM (`AVAudioFile` или декодер Ogg) не потокобезопасен, поэтому `produce` и `replenish` вызываются
/// только на последовательной `AudioEngine.decodeQueue`, а главный поток лишь хранит ссылку.
final class AudioTransitionStream: AudioChunkProducer, @unchecked Sendable {
    /// Буфер после `produce` больше не изменяется декодером: он передаётся
    /// на главный поток и далее только в `AVAudioPlayerNode.scheduleBuffer`.
    struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let boundary: AudioStreamBoundary?
    }

    private final class Source {
        let item: AudioStreamItem
        let url: URL
        let file: AudioPCMSource
        let access: Bool
        let info: AudioEngine.Info
        let factor: Float
        let album: String?
        let artist: String?
        var remaining: AVAudioFramePosition { max(0, file.length - file.framePosition) }

        init(item: AudioStreamItem, resolved: URL?, options: AudioPlaybackOptions, equalizer: EqualizerSettings) throws {
            self.item = item
            if let resolved = resolved { url = resolved }
            else if let bookmark = item.track.bookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            } else { url = item.track.url }
            access = url.startAccessingSecurityScopedResource()
            do { file = try AudioDecoding.open(url) }
            catch {
                if access { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            info = AudioEngine.describe(file, url: url)
            let tags = (options.replayGain != .off || options.crossfade > 0 && options.preserveAlbums)
                ? try? AudioMetadataFile.read(url, includeArtwork: false) : nil
            factor = Float(pow(10, options.gain(item.cachedGain ?? tags?.replayGain ?? ReplayGainValues(),
                                                equalizer: equalizer) / 20))
            album = tags?.fields[.album]?.trimmingCharacters(in: .whitespacesAndNewlines)
            artist = tags?.fields[.albumArtist] ?? tags?.fields[.artist]
        }

        deinit { if access { url.stopAccessingSecurityScopedResource() } }

        func read(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                throw AudioDecoding.Failure.invalidAudio
            }
            try file.read(into: buffer, frameCount: frames)
            return buffer
        }
    }

    private let plan: AudioStreamPlan
    private let resolved: URL
    private let start: AVAudioFramePosition
    private var current: Source?
    private var pending: [AudioStreamItem]
    private var next: Source?
    private var ordinal = 0
    private var overlap: AVAudioFramePosition = 0
    private var mixed: AVAudioFramePosition = 0
    private var exhausted = false

    init(plan: AudioStreamPlan, url: URL, start: AVAudioFramePosition) {
        self.plan = plan
        resolved = url
        self.start = start
        pending = plan.upcoming
    }

    /// Когда UI догнал уже запланированную границу, пополняем список с учётом
    /// того, насколько декодер ушёл вперёд по очереди.
    func replenish(after anchor: Int, with items: [AudioStreamItem]) {
        let distance = ordinal - anchor
        guard !exhausted, distance >= 0, distance <= items.count else { return }
        if distance > 0, items[distance - 1].track.id != current?.item.track.id { return }
        var remaining = Array(items.dropFirst(distance))
        if let next = next {
            guard remaining.first?.track.id == next.item.track.id else { return }
            remaining.removeFirst()
        }
        pending = remaining
    }

    func produce(maximum: Int) throws -> (chunks: [Chunk], done: Bool) {
        if current == nil && !exhausted {
            let source = try Source(item: plan.current, resolved: resolved, options: plan.options, equalizer: plan.equalizer)
            source.file.framePosition = min(start, max(0, source.file.length - 1))
            current = source
        }
        var chunks: [Chunk] = []
        while chunks.count < maximum && !exhausted, let source = current {
            prepareNext(for: source)
            let inFade = overlap > 0 && source.remaining <= overlap - mixed
            let available = inFade ? overlap - mixed : source.remaining - overlap
            let requested = AVAudioFrameCount(min(4096, max(0, available)))
            guard requested > 0 else { exhausted = true; break }
            let buffer = try source.read(requested)
            guard buffer.frameLength > 0 else { exhausted = true; break }
            if inFade, let incoming = next {
                let head = try incoming.read(buffer.frameLength)
                blend(buffer, from: head, outgoingGain: source.factor, incomingGain: incoming.factor)
                mixed += AVAudioFramePosition(buffer.frameLength)
            } else {
                scale(buffer, by: source.factor)
            }
            let finished = source.remaining == 0 || buffer.frameLength < requested
            var boundary: AudioStreamBoundary?
            if finished, let incoming = next {
                ordinal += 1
                boundary = AudioStreamBoundary(item: incoming.item, url: incoming.url, info: incoming.info,
                                               consumed: incoming.file.framePosition, ordinal: ordinal)
                current = incoming
                next = nil
                overlap = 0
                mixed = 0
            } else if finished {
                exhausted = true
            }
            chunks.append(Chunk(buffer: buffer, boundary: boundary))
        }
        return (chunks, exhausted)
    }

    private func prepareNext(for source: Source) {
        guard next == nil, let item = pending.first else { return }
        pending.removeFirst()
        guard let incoming = try? Source(item: item, resolved: nil, options: plan.options, equalizer: plan.equalizer),
              incoming.file.processingFormat.isEqual(source.file.processingFormat) else {
            // Порядок сохраняется: несовместимый или недоступный следующий файл
            // должен быть открыт обычным маршрутом, а не пропущен.
            pending.removeAll()
            return
        }
        let seconds = plan.options.crossfade
        let sharedAlbum = plan.options.preserveAlbums && source.album?.isEmpty == false &&
            source.album?.localizedCaseInsensitiveCompare(incoming.album ?? "") == .orderedSame &&
            (source.artist ?? "").localizedCaseInsensitiveCompare(incoming.artist ?? "") == .orderedSame
        let canMix = seconds > 0 && !sharedAlbum && source.item.track.id != item.track.id
        guard canMix || plan.options.gapless || (seconds > 0 && sharedAlbum) else {
            pending.removeAll()
            return
        }
        if canMix {
            let requested = AVAudioFramePosition(seconds * source.file.processingFormat.sampleRate)
            overlap = min(requested, source.file.length / 2, incoming.file.length / 2, source.remaining)
        }
        next = incoming
    }

    private func scale(_ buffer: AVAudioPCMBuffer, by gain: Float) {
        guard gain != 1, let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { channels[channel][frame] *= gain }
        }
    }

    /// Линейные комплементарные огибающие удерживают сумму весов равной единице.
    private func blend(_ tail: AVAudioPCMBuffer, from head: AVAudioPCMBuffer, outgoingGain: Float, incomingGain: Float) {
        guard let outgoing = tail.floatChannelData, let incoming = head.floatChannelData else { return }
        for channel in 0..<Int(tail.format.channelCount) {
            for frame in 0..<Int(tail.frameLength) {
                let fraction = Float(mixed + AVAudioFramePosition(frame) + 1) / Float(overlap + 1)
                let sample = frame < Int(head.frameLength) ? incoming[channel][frame] : 0
                outgoing[channel][frame] = outgoing[channel][frame] * outgoingGain * (1 - fraction) +
                    sample * incomingGain * fraction
            }
        }
    }
}
