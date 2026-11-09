import Foundation
import VibeWaveCore

/// Очередь воспроизведения и управление AudioEngine. Очередь хранится отдельно
/// от просматриваемого раздела: переключение раздела не меняет то, что играет.
extension PlayerModel {
    var nextTrack: Track? {
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }), index + 1 < queue.count else { return nil }
        return queue[index + 1]
    }

    var playbackTracks: [Track]? {
        switch playbackSource {
        case .library: return libraryQueue(startingSection: librarySectionStart)
        case .container(let id): return tracks(in: id)
        }
    }

    /// Изменения библиотеки обновляют следующие треки, не прерывая текущий.
    func refreshPlaybackQueue() {
        guard current != nil, let tracks = playbackTracks else { return }
        queue = tracks
    }

    func play(_ track: Track, in tracks: [Track], playlistID: UUID? = nil) {
        queue = tracks
        playbackSource = .container(playlistID)
        startTrack(track)
    }

    /// section — ID раздела режима «По плейлистам», из которого запущен трек.
    func playLibrary(_ track: Track, section: String? = nil) {
        librarySectionStart = groupByPlaylists ? section : nil
        queue = libraryQueue(startingSection: librarySectionStart)
        playbackSource = .library
        startTrack(track)
    }

    func toggle() {
        guard engine.isLoaded else {
            let tracks = visibleTracks
            guard let first = tracks.first else { return }
            if isLibrarySelected { playLibrary(first) } else { play(first, in: tracks, playlistID: selectedID) }
            return
        }
        if playing {
            engine.pause()
            timer = nil
            playing = false
        } else {
            guard engine.play() else { error = "Не удалось продолжить воспроизведение."; return }
            playing = true
            startTimer()
        }
    }

    func seek(_ value: Double) {
        let target = max(0, min(value, duration))
        engine.currentTime = target
        position = target
    }

    func next() {
        if let next = nextTrack { startTrack(next) } else { stop() }
    }

    func previous() {
        if position > 3 { seek(0); return }
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        startTrack(queue[max(0, index - 1)])
    }

    func stop() {
        timer = nil
        engine.unload()
        playing = false
        current = nil
        position = 0
        duration = 0
        currentBitrate = 0
        currentSampleRate = 0
        currentChannels = 0
    }

    /// Уровни левого и правого канала 0…1 для индикатора; без воспроизведения — нули.
    func meterLevels() -> (Double, Double) {
        playing ? engine.meterLevels() : (0, 0)
    }

    // MARK: События AudioEngine

    func trackFinished(successfully flag: Bool) {
        if flag { next() }
        else { stop(); error = "Файл не удалось воспроизвести до конца." }
    }

    func decodeFailed(_ error: Error?) {
        stop()
        self.error = "Ошибка декодирования: \(error?.localizedDescription ?? "повреждённый файл")"
    }

    // MARK: Внутреннее

    /// Переход вперёд/назад идёт по текущей очереди.
    private func startTrack(_ track: Track) {
        stop()
        do {
            let info = try engine.load(try resolvedURL(of: track))
            currentBitrate = info.bitrate
            currentSampleRate = info.sampleRate
            currentChannels = info.channels
            guard engine.play() else { throw NSError(domain: "VibeWave", code: 1, userInfo: [NSLocalizedDescriptionKey: "Аудиоустройство недоступно."]) }
            current = track
            duration = info.duration
            playing = true
            startTimer()
        } catch {
            stop()
            self.error = "Не удалось воспроизвести «\(track.title)»: \(error.localizedDescription)"
        }
    }

    /// Закладка позволяет найти файл после перемещения; устаревшая закладка пересоздаётся
    /// во всех источниках, где встречается трек.
    private func resolvedURL(of track: Track) throws -> URL {
        guard let data = track.bookmark else { return track.url }
        var stale = false
        let resolved = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard stale else { return resolved }
        let scoped = resolved.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
        let fresh = try resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        func update(_ tracks: inout [Track]) {
            guard let row = tracks.firstIndex(where: { $0.id == track.id }) else { return }
            tracks[row].bookmark = fresh
            tracks[row].url = resolved
        }
        for index in playlists.indices { update(&playlists[index].tracks) }
        for index in folders.indices { update(&folders[index].tracks) }
        update(&openTracks)
        save()
        return resolved
    }

    private func startTimer() {
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self else { return }
            self.position = self.engine.currentTime
        }
    }
}
