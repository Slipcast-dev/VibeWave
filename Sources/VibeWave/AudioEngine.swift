import AVFoundation
import Foundation
import VibeWaveCore

/// Воспроизведение текущего трека через AVAudioEngine:
/// файл или PCM-очередь → AVAudioPlayerNode → ReplayGain → EQ → баланс и громкость → выход.
/// Отвечает также за security-scoped доступ к файлу, перемотку и уровни каналов.
/// Очередь и библиотека находятся в PlayerModel.
@MainActor
final class AudioEngine {
    struct Info: Sendable {
        let duration: Double
        let bitrate: Int
        let sampleRate: Double
        let channels: Int
    }

    /// Трек доигран до конца.
    var onFinish: (() -> Void)?
    /// Воспроизведение остановилось само (например, после смены аудиоустройства не удалось продолжить).
    var onFailure: ((Error) -> Void)?
    var onTransition: ((AudioStreamBoundary, TimeInterval) -> Void)?
    var onRecovered: ((TimeInterval) -> Void)?
    var volume: Float = 0.75 { didSet { balance.volume = volume } }
    var pan: Float = 0 { didSet { balance.pan = pan } }
    var equalizer = EqualizerSettings() { didSet { applyEqualizer() } }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let normalizer = AVAudioUnitEQ(numberOfBands: 1)
    private let eq = AVAudioUnitEQ(numberOfBands: EqualizerSettings.frequencies.count)
    /// Промежуточный микшер: его pan и volume применяются на входе основного микшера.
    private let balance = AVAudioMixerNode()
    private let meter = LevelMeter()
    private var file: AVAudioFile?
    private var activeInfo: Info?
    private var activeURL: URL?
    private var activeFormat: AVAudioFormat?
    private var plan: AudioStreamPlan?
    private let decodeQueue = DispatchQueue(label: "VibeWave.audio-transition", qos: .userInitiated)
    private var stream: AudioTransitionStream?
    private var decoding = false
    private var streamDone = false
    private var scheduledCount = 0
    private var submittedFrames: AVAudioFramePosition = 0
    private var timelineOrigin: AVAudioFramePosition = 0
    private var accessedURL: URL?
    /// Кадр файла, с которого запланировано воспроизведение (после перемотки).
    private var startFrame: AVAudioFramePosition = 0
    /// Последняя доступная позиция, в том числе после сброса аудиоустройства.
    private var stoppedTime: Double = 0
    /// Отличает актуальное расписание от уже отменённого: завершение старого сегмента игнорируется.
    private var generation = 0
    private(set) var isPlaying = false
    private var configurationObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        engine.attach(normalizer)
        normalizer.bands[0].bypass = true
        normalizer.bypass = true
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
            DispatchQueue.main.async { [weak self] in self?.recoverAfterConfigurationChange() }
        }
    }

    var isLoaded: Bool { activeInfo != nil }
    var duration: Double { activeInfo?.duration ?? 0 }

    var currentTime: Double {
        guard isPlaying, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.sampleRate > 0 else { return stoppedTime }
        let frame = startFrame + playerTime.sampleTime - timelineOrigin
        stoppedTime = min(duration, max(0, Double(frame) / playerTime.sampleRate))
        return stoppedTime
    }

    nonisolated static func describe(_ file: AVAudioFile, url: URL) -> Info {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let bitrate = seconds > 0 ? Int(exactly: (Double(size) * 8 / seconds / 1000).rounded()) ?? 0 : 0
        return Info(duration: seconds, bitrate: bitrate, sampleRate: file.fileFormat.sampleRate,
                    channels: Int(file.fileFormat.channelCount))
    }

    /// Загружает файл вместо текущего (без запуска). Ошибка оставляет движок пустым.
    func load(_ url: URL) throws -> Info {
        unload()
        do {
            try openNativeFile(url)
            guard let file = file else { throw AudioDecoding.Failure.invalidAudio }
            let info = Self.describe(file, url: url)
            activeInfo = info
            activeURL = url
            activeFormat = file.processingFormat
            try connectAndStart(format: file.processingFormat)
            schedule(from: 0)
            return info
        } catch {
            unload()
            throw error
        }
    }

    /// Очередь PCM пересоздаётся после изменения будущего порядка. В нативном
    /// режиме пересчёт ReplayGain меняет только усиление, без перерыва звука.
    func configurePlayback(_ newPlan: AudioStreamPlan) {
        guard isLoaded, plan != newPlan else { return }
        let wasStreaming = stream != nil
        plan = newPlan
        if wasStreaming || newPlan.options.usesTransitions {
            seek(to: currentTime)
        } else {
            applyReplayGain()
        }
    }

    func replenish(_ newPlan: AudioStreamPlan, after ordinal: Int) {
        plan = newPlan
        guard let stream = stream else { return }
        decodeQueue.async { stream.replenish(after: ordinal, with: newPlan.upcoming) }
    }

    func play() -> Bool {
        guard isLoaded else { return false }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        isPlaying = true
        if stream != nil {
            if scheduledCount > 0 { player.play() }
            if streamDone && scheduledCount == 0 {
                let current = generation
                DispatchQueue.main.async { [weak self] in self?.segmentFinished(current) }
            } else {
                pump()
            }
        } else {
            player.play()
        }
        return true
    }

    func pause() {
        stoppedTime = currentTime
        player.pause()
        isPlaying = false
    }

    /// Последний кадр остаётся в расписании, чтобы перемотка в конец завершила трек.
    func seek(to seconds: Double) {
        guard let url = activeURL, let rate = activeFormat?.sampleRate else { return }
        let frame = min(AVAudioFramePosition(max(0, min(seconds, duration)) * rate),
                        max(0, AVAudioFramePosition((duration * rate).rounded()) - 1))
        let wasPlaying = isPlaying
        resetSchedule()
        isPlaying = false
        stoppedTime = Double(frame) / rate
        do {
            if let plan = plan, plan.options.usesTransitions {
                stream = AudioTransitionStream(plan: plan, url: url, start: frame)
                startFrame = frame
            } else {
                if file?.url != url { try openNativeFile(url) }
                schedule(from: frame)
            }
            applyReplayGain()
            if wasPlaying, !play() { throw CocoaError(.featureUnsupported) }
        } catch {
            onFailure?(error)
        }
    }

    func unload() {
        resetSchedule()
        engine.stop()
        file = nil
        activeInfo = nil
        activeURL = nil
        activeFormat = nil
        plan = nil
        isPlaying = false
        startFrame = 0
        stoppedTime = 0
        normalizer.bypass = true
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
        engine.connect(player, to: normalizer, format: format)
        engine.connect(normalizer, to: eq, format: format)
        engine.connect(eq, to: balance, format: format)
        engine.prepare()
        try engine.start()
    }

    private func openNativeFile(_ url: URL) throws {
        file = nil
        if let accessedURL = accessedURL { accessedURL.stopAccessingSecurityScopedResource() }
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        file = try AudioDecoding.open(url)
    }

    private func applyReplayGain() {
        guard stream == nil, let plan = plan, let url = activeURL, plan.options.replayGain != .off else {
            normalizer.bypass = true
            return
        }
        let values = plan.current.cachedGain ?? (try? AudioMetadataFile.read(url, includeArtwork: false).replayGain)
        let gain = plan.options.gain(values ?? ReplayGainValues(), equalizer: plan.equalizer)
        normalizer.globalGain = Float(gain)
        normalizer.bypass = gain == 0
    }

    private func resetSchedule() {
        generation += 1
        player.stop()
        stream = nil
        decoding = false
        streamDone = false
        scheduledCount = 0
        submittedFrames = 0
        timelineOrigin = 0
    }

    /// Поддерживает очередь коротких буферов. Время UI и текущий трек
    /// меняются при проигранной границе, а не при её декодировании.
    private func pump() {
        guard isPlaying, let stream = stream, !decoding, !streamDone, scheduledCount < 6 else { return }
        let current = generation
        let capacity = 6 - scheduledCount
        decoding = true
        decodeQueue.async { [weak self] in
            let result = Result { try stream.produce(maximum: capacity) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, current == self.generation else { return }
                self.decoding = false
                switch result {
                case .failure(let error):
                    self.pause()
                    self.resetSchedule()
                    self.onFailure?(error)
                case .success(let batch):
                    self.streamDone = batch.done
                    for chunk in batch.chunks { self.enqueue(chunk, generation: current) }
                    if self.isPlaying && self.scheduledCount > 0 && !self.player.isPlaying { self.player.play() }
                    if self.streamDone && self.scheduledCount == 0 { self.segmentFinished(current) }
                    else { self.pump() }
                }
            }
        }
    }

    private func enqueue(_ chunk: AudioTransitionStream.Chunk, generation current: Int) {
        submittedFrames += AVAudioFramePosition(chunk.buffer.frameLength)
        let frameEnd = submittedFrames
        let boundary = chunk.boundary
        scheduledCount += 1
        player.scheduleBuffer(chunk.buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.bufferFinished(current, frameEnd: frameEnd, boundary: boundary) }
        }
    }

    private func bufferFinished(_ current: Int, frameEnd: AVAudioFramePosition, boundary: AudioStreamBoundary?) {
        guard generation == current else { return }
        scheduledCount -= 1
        if let boundary = boundary {
            activeInfo = boundary.info
            activeURL = boundary.url
            timelineOrigin = frameEnd
            startFrame = boundary.consumed
            stoppedTime = Double(boundary.consumed) / (activeFormat?.sampleRate ?? boundary.info.sampleRate)
            onTransition?(boundary, stoppedTime)
        }
        if streamDone && scheduledCount == 0 { segmentFinished(current) }
        else { pump() }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file = file else { return }
        generation += 1
        let current = generation
        player.stop()
        startFrame = max(0, min(frame, file.length))
        // scheduleSegment принимает UInt32 кадров. У длинного WAV/CAF
        // планируем несколько смежных участков и ждём только последний.
        let length = file.length
        var offset = startFrame
        while offset < length {
            let count = min(length - offset, AVAudioFramePosition(AVAudioFrameCount.max))
            let last = offset + count == length
            player.scheduleSegment(file, startingFrame: offset, frameCount: AVAudioFrameCount(count),
                                   at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard last else { return }
                DispatchQueue.main.async { [weak self] in self?.segmentFinished(current) }
            }
            offset += count
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
        guard let format = activeFormat else { return }
        let time = currentTime
        let wasPlaying = isPlaying
        isPlaying = false
        do {
            try connectAndStart(format: format)
            seek(to: time)
            if wasPlaying {
                guard play() else { throw CocoaError(.featureUnsupported) }
                onRecovered?(time)
            }
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
