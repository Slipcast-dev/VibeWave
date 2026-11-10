import Combine
import MediaPlayer

/// Системные команды относятся к активному источнику Now Playing.
@MainActor
final class MediaKeyControls {
    private weak var model: PlayerModel?
    private let commands = MPRemoteCommandCenter.shared()
    private let nowPlaying = MPNowPlayingInfoCenter.default()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var observation: AnyCancellable?
    private var hasPlayed = false

    init(model: PlayerModel) { self.model = model }

    func start() {
        guard let model = model, observation == nil else { return }
        register(commands.togglePlayPauseCommand) { model, _ in model.toggle() }
        register(commands.playCommand) { model, _ in if !model.playing { model.toggle() } }
        register(commands.pauseCommand) { model, _ in if model.playing { model.toggle() } }
        register(commands.stopCommand) { model, _ in model.stop() }
        register(commands.nextTrackCommand) { model, _ in model.next() }
        register(commands.previousTrackCommand) { model, _ in model.previous() }
        register(commands.changePlaybackPositionCommand) { model, event in
            if let seek = event as? MPChangePlaybackPositionCommandEvent, seek.positionTime.isFinite {
                model.seek(seek.positionTime)
            }
        }
        observation = Publishers.CombineLatest3(model.$current, model.$playing, model.$position)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
        publish()
    }

    func stop() {
        guard observation != nil else { return }
        observation = nil
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
        clear()
    }

    private func register(_ command: MPRemoteCommand, handler: @escaping (PlayerModel, MPRemoteCommandEvent) -> Void) {
        command.isEnabled = false
        let token = command.addTarget { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.hasPlayed, let model = self.model, model.current != nil else { return }
                handler(model, event)
            }
            return .success
        }
        targets.append((command, token))
    }

    private func publish() {
        guard let model = model, let track = model.current else { clear(); return }
        hasPlayed = hasPlayed || model.playing
        guard hasPlayed else { return } // Восстановленная пауза не захватывает медиаклавиши при запуске.
        for (command, _) in targets where !command.isEnabled { command.isEnabled = true }
        nowPlaying.nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: model.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.position,
            MPNowPlayingInfoPropertyPlaybackRate: model.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        let state: MPNowPlayingPlaybackState = model.playing ? .playing : .paused
        if nowPlaying.playbackState != state { nowPlaying.playbackState = state }
    }

    private func clear() {
        guard hasPlayed else { return }
        hasPlayed = false
        for (command, _) in targets { command.isEnabled = false }
        nowPlaying.nowPlayingInfo = nil
        nowPlaying.playbackState = .stopped
    }
}
