import AVFoundation
import Foundation

/// Декодер текущего трека: AVAudioPlayer, security-scoped доступ к файлу и уведомления
/// о завершении. Очередь и библиотека находятся в PlayerModel.
@MainActor
final class AudioEngine: NSObject {
    struct Info {
        let duration: Double
        let bitrate: Int
        let sampleRate: Double
        let channels: Int
    }

    /// true — трек доигран до конца, false — воспроизведение прервано.
    var onFinish: ((Bool) -> Void)?
    var onDecodeError: ((Error?) -> Void)?
    var volume: Float = 0.75 { didSet { player?.volume = volume } }
    var pan: Float = 0 { didSet { player?.pan = pan } }

    private var player: AVAudioPlayer?
    private var accessedURL: URL?

    var isLoaded: Bool { player != nil }
    var currentTime: Double {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }

    /// Загружает файл вместо текущего. Ошибка оставляет движок пустым.
    func load(_ url: URL) throws -> Info {
        unload()
        if url.startAccessingSecurityScopedResource() { accessedURL = url }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.delegate = self
            audio.volume = volume
            audio.pan = pan
            audio.isMeteringEnabled = true
            player = audio
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let bitrate = audio.duration > 0 ? Int((Double(size) * 8 / audio.duration / 1000).rounded()) : 0
            return Info(duration: audio.duration, bitrate: bitrate, sampleRate: audio.format.sampleRate,
                        channels: Int(audio.format.channelCount))
        } catch {
            unload()
            throw error
        }
    }

    func play() -> Bool { player?.play() ?? false }
    func pause() { player?.pause() }

    func unload() {
        player?.stop()
        player = nil
        if let url = accessedURL { url.stopAccessingSecurityScopedResource() }
        accessedURL = nil
    }

    /// Уровни левого и правого канала 0…1 для индикатора.
    func meterLevels() -> (Double, Double) {
        guard let player = player else { return (0, 0) }
        player.updateMeters()
        func level(_ channel: Int) -> Double {
            let power = Double(player.averagePower(forChannel: min(channel, player.numberOfChannels - 1)))
            return power.isFinite ? max(0, min(1, (power + 50) / 50)) : 0
        }
        return (level(0), level(1))
    }

    /// Событие от уже заменённого декодера игнорируется.
    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        player.map { ObjectIdentifier($0) == id } ?? false
    }

    fileprivate func finished(_ id: ObjectIdentifier, successfully flag: Bool) {
        guard isCurrent(id) else { return }
        onFinish?(flag)
    }

    fileprivate func failed(_ id: ObjectIdentifier, error: Error?) {
        guard isCurrent(id) else { return }
        onDecodeError?(error)
    }
}

extension AudioEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in self?.finished(id, successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        let message = error.map { $0 as NSError }
        DispatchQueue.main.async { [weak self] in self?.failed(id, error: message) }
    }
}
