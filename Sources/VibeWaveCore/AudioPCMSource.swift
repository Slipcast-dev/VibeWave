import AVFoundation
import Foundation

/// Порционное чтение PCM с перемоткой. Плеер, переходы, проверка импорта и анализ
/// ReplayGain работают с этим интерфейсом, а не с конкретным декодером.
///
/// Контракт повторяет `AVAudioFile`: `processingFormat` — Float32 без чередования,
/// `length` и `framePosition` считаются в кадрах этого формата, `read` заполняет буфер
/// с текущей позиции и сдвигает её. Источник не потокобезопасен: все вызовы одного
/// экземпляра выполняются последовательно.
public protocol AudioPCMSource: AnyObject {
    var processingFormat: AVAudioFormat { get }
    /// Формат кодека в файле: идентификатор, частота, каналы.
    var fileFormat: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    var framePosition: AVAudioFramePosition { get set }
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws
}

extension AVAudioFile: AudioPCMSource {}

public extension AudioPCMSource {
    func read(into buffer: AVAudioPCMBuffer) throws {
        try read(into: buffer, frameCount: buffer.frameCapacity)
    }
}

public enum AudioPCMSources {
    /// Собственный тракт для Ogg одинаков на всех версиях macOS: штатное чтение Ogg
    /// отсутствует на macOS 13, а на новых системах неточно обрезает Vorbis.
    public static func open(_ url: URL) throws -> AudioPCMSource {
        if AudioFormat(url: url) == .ogg { return try OggAudioSource(url: url) }
        return try AVAudioFile(forReading: url)
    }

    /// Источник с явно заданным форматом обработки для анализа громкости.
    static func openFloat32(_ url: URL) throws -> AudioPCMSource {
        if AudioFormat(url: url) == .ogg { return try OggAudioSource(url: url) }
        return try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}
