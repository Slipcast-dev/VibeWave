import AVFoundation
import Foundation
import VibeWaveCore

/// Воспроизведение текущего трека через AVAudioEngine:
/// файл → AVAudioPlayerNode → эквалайзер (AVAudioUnitEQ) → баланс и громкость → выход.
/// Отвечает также за security-scoped доступ к файлу, перемотку и уровни каналов.
/// Очередь и библиотека находятся в PlayerModel.
@MainActor
final class AudioEngine {
    struct Info {
        let duration: Double
        let bitrate: Int
        let sampleRate: Double
        let channels: Int
    }

    /// Трек доигран до конца.
    var onFinish: (() -> Void)?
    /// Воспроизведение остановилось само (например, после смены аудиоустройства не удалось продолжить).
    var onFailure: ((Error) -> Void)?
    var volume: Float = 0.75 { didSet { balance.volume = volume } }
    var pan: Float = 0 { didSet { balance.pan = pan } }
    var equalizer = EqualizerSettings() { didSet { applyEqualizer() } }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: EqualizerSettings.frequencies.count)
    /// Промежуточный микшер: его pan и volume применяются на входе основного микшера.
    private let balance = AVAudioMixerNode()
    private let meter = LevelMeter()
    private var file: AVAudioFile?
    private var accessedURL: URL?
    /// Кадр файла, с которого запланировано воспроизведение (после перемотки).
    private var startFrame: AVAudioFramePosition = 0
    /// Позиция, когда плеер не играет.
    private var stoppedTime: Double = 0
    /// Отличает актуальное расписание от уже отменённого: завершение старого сегмента игнорируется.
    private var generation = 0
    private(set) var isPlaying = false
    private var configurationObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        engine.attach(eq)
        engine.attach(balance)
        for (band, frequency) in zip(eq.bands, EqualizerSettings.frequencies) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1 // октава
            band.bypass = false
        }
        engine.connect(balance, to: engine.mainMixerNode, format: nil)
        balance.volume = volume
        let meter = meter
        balance.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.update(buffer) }
        applyEqualizer()
        // Смена выхода (наушники, AirPods) останавливает движок: восстанавливаем позицию и состояние.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.recoverAfterConfigurationChange() }
        }
    }

    var isLoaded: Bool { file != nil }

    var duration: Double {
        guard let file = file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: Double {
        guard file != nil else { return 0 }
        guard isPlaying, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.sampleRate > 0 else { return stoppedTime }
        return min(duration, max(0, Double(startFrame + playerTime.sampleTime) / playerTime.sampleRate))
    }

    /// Загружает файл вместо текущего (без запуска). Ошибка оставляет движок пустым.
    func load(_ url: URL) throws -> Info {
        unload()
        if url.startAccessingSecurityScopedResource() { accessedURL = url }
        do {
            let file = try AVAudioFile(forReading: url)
            self.file = file
            try connectAndStart(format: file.processingFormat)
            schedule(from: 0)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let seconds = duration
            let bitrate = seconds > 0 ? Int((Double(size) * 8 / seconds / 1000).rounded()) : 0
            return Info(duration: seconds, bitrate: bitrate, sampleRate: file.fileFormat.sampleRate,
                        channels: Int(file.fileFormat.channelCount))
        } catch {
            unload()
            throw error
        }
    }

    func play() -> Bool {
        guard file != nil else { return false }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        player.play()
        isPlaying = true
        return true
    }

    func pause() {
        stoppedTime = currentTime
        player.pause()
        isPlaying = false
    }

    /// Перемотка; при воспроизведении звук продолжается с новой позиции.
    func seek(to seconds: Double) {
        guard let file = file else { return }
        let rate = file.processingFormat.sampleRate
        // Последний кадр остаётся в расписании, чтобы перемотка в конец штатно завершила трек.
        let frame = min(AVAudioFramePosition(max(0, seconds) * rate), max(0, file.length - 1))
        let wasPlaying = isPlaying
        schedule(from: frame)
        stoppedTime = Double(frame) / rate
        if wasPlaying { player.play() }
    }

    func unload() {
        generation += 1
        player.stop()
        engine.stop()
        file = nil
        isPlaying = false
        startFrame = 0
        stoppedTime = 0
        meter.reset()
        if let url = accessedURL { url.stopAccessingSecurityScopedResource() }
        accessedURL = nil
    }

    /// Уровни левого и правого канала 0…1 для индикатора.
    func meterLevels() -> (Double, Double) {
        isPlaying ? meter.levels : (0, 0)
    }

    // MARK: Внутреннее

    private func connectAndStart(format: AVAudioFormat) throws {
        engine.stop()
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: balance, format: format)
        engine.prepare()
        try engine.start()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file = file else { return }
        generation += 1
        let current = generation
        player.stop()
        startFrame = max(0, min(frame, file.length))
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(current) }
        }
    }

    private func segmentFinished(_ finished: Int) {
        guard finished == generation, isPlaying else { return }
        isPlaying = false
        stoppedTime = duration
        onFinish?()
    }

    private func applyEqualizer() {
        eq.bypass = !equalizer.enabled
        eq.globalGain = equalizer.preamp
        for (band, gain) in zip(eq.bands, equalizer.gains) { band.gain = gain }
    }

    private func recoverAfterConfigurationChange() {
        guard let file = file else { return }
        let time = currentTime
        let wasPlaying = isPlaying
        isPlaying = false
        do {
            try connectAndStart(format: file.processingFormat)
            seek(to: time)
            if wasPlaying, !play() { throw CocoaError(.featureUnsupported) }
        } catch {
            stoppedTime = time
            onFailure?(error)
        }
    }
}

/// Уровни каналов из отвода микшера. Буферы приходят из потока звука, чтение — с главного.
private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (Double, Double) = (0, 0)

    var levels: (Double, Double) {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func reset() {
        lock.lock()
        current = (0, 0)
        lock.unlock()
    }

    func update(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        func level(_ channel: Int) -> Double {
            let samples = data[min(channel, channels - 1)]
            var sum: Float = 0
            for index in 0..<frames { sum += samples[index] * samples[index] }
            let decibels = 20 * log10(max(sqrt(sum / Float(frames)), 1e-7))
            // Шкала как у прежнего индикатора: −50 дБ…0 дБ → 0…1.
            return max(0, min(1, (Double(decibels) + 50) / 50))
        }
        let value = (level(0), level(1))
        lock.lock()
        current = value
        lock.unlock()
    }
}
