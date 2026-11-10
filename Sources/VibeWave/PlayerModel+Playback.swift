import Foundation
import os
import VibeWaveCore

/// Очередь воспроизведения и управление AudioEngine. Очередь хранится отдельно
/// от просматриваемого раздела: переключение раздела не меняет то, что играет.
extension PlayerModel {
    var nextTrack: Track? {
        guard let id = current?.id else { return nil }
        if shuffleEnabled {
            return queue.first { $0.id == shuffleOrder.next }
        }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return queue.first }
        if index + 1 < queue.count { return queue[index + 1] }
        return repeatMode == .queue ? queue.first : nil
    }

    var playbackTracks: [Track]? {
        switch playbackSource {
        case .library: return libraryQueue(startingSection: librarySectionStart)
        case .container(let id): return tracks(in: id)
        case .snapshot: return queue
        }
    }

    /// Изменения библиотеки обновляют следующие треки и сохраняют текущую позицию.
    func refreshPlaybackQueue() {
        guard let current = current else { return }
        queue = playbackTracks ?? []
        if shuffleEnabled { shuffleOrder.update(queue.map(\.id), current: current.id) }
        configureAudio()
    }

    func play(_ track: Track, in tracks: [Track], playlistID: UUID? = nil) {
        playbackSource = .container(playlistID)
        startQueue(tracks, at: track)
    }

    /// section — ID раздела режима «По плейлистам», из которого запущен трек.
    func playLibrary(_ track: Track, section: String? = nil) {
        librarySectionStart = groupByPlaylists ? section : nil
        playbackSource = .library
        startQueue(libraryQueue(startingSection: librarySectionStart), at: track)
    }

    /// Выдача берётся снимком при запуске. Изменение поиска или правил не перестраивает текущую очередь.
    func playQuery(_ track: Track) {
        playbackSource = .snapshot
        startQueue(queryResults.map(\.track), at: track)
    }

    func toggle() {
        guard engine.isLoaded else {
            let tracks = displayedTracks
            guard let first = tracks.first else { return }
            if showsQueryResults { playQuery(first) }
            else if isLibrarySelected { playLibrary(first) }
            else { play(first, in: tracks, playlistID: selectedID) }
            return
        }
        if playing {
            sampleListening(at: engine.currentTime)
            listeningSession.suspend()
            engine.pause()
            timer = nil
            playing = false
        } else {
            guard engine.play() else { error = strings.errorResume; return }
            playing = true
            resumeListening(at: engine.currentTime)
            startTimer()
        }
    }

    func seek(_ value: Double) {
        let target = max(0, min(value, duration))
        if playing { sampleListening(at: engine.currentTime) }
        engine.seek(to: target)
        if playing { resumeListening(at: engine.currentTime) }
        position = target
    }

    func next() {
        guard let current = current else { return }
        let following: Track?
        if shuffleEnabled {
            let id = shuffleOrder.advance(from: current.id, repeatingQueue: repeatMode == .queue)
            following = queue.first { $0.id == id }
        } else {
            following = nextTrack
        }
        if let following = following { startTrack(following) } else { stop() }
    }

    /// Ручной переход всегда идёт по очереди. Повтор трека действует при его завершении.
    func trackFinished() {
        sampleListening(at: duration)
        listeningSession.suspend()
        if repeatMode == .track, let current = current, queue.contains(where: { $0.id == current.id }) {
            startTrack(current)
        } else {
            next()
        }
    }

    func previous() {
        if position > 3 { seek(0); return }
        guard let current = current else { return }
        if shuffleEnabled {
            let id = shuffleOrder.retreat(from: current.id)
            if let track = queue.first(where: { $0.id == id }) { startTrack(track) }
            else { seek(0) }
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == current.id }) else { return }
        startTrack(queue[max(0, index - 1)])
    }

    func stop(preservingSession: Bool = false) {
        if !preservingSession { clearPlaybackSession() }
        clearPlaybackState()
    }

    private func clearPlaybackState() {
        if playing { sampleListening(at: engine.currentTime) }
        listeningSession = ListeningSession()
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

    // MARK: Восстановление сеанса

    /// Сохраняем точную позицию движка, включая время между обновлениями индикатора.
    func savePlaybackSession() {
        guard restorePlaybackOnLaunch, let current = current, engine.isLoaded else { return }
        let snapshot = PlaybackSession(current: current, position: engine.currentTime, queue: queue,
                                       openTracks: openTracks, source: playbackSource, librarySection: librarySectionStart,
                                       shuffleOrder: shuffleEnabled ? shuffleOrder : nil)
        do { try playbackSessionStore.save(snapshot) }
        catch { playbackSessionLogger.error("Could not save playback session: \(error.localizedDescription)") }
    }

    func clearPlaybackSession() {
        do { try playbackSessionStore.clear() }
        catch { playbackSessionLogger.error("Could not clear playback session: \(error.localizedDescription)") }
    }

    /// В очереди сохраняется порядок прошлого сеанса. Записи из медиатеки
    /// получают актуальные данные и закладки по своему идентификатору.
    func restorePlaybackSession() {
        guard restorePlaybackOnLaunch, current == nil, !importing else { return }
        let stored: PlaybackSession?
        do { stored = try playbackSessionStore.load() }
        catch {
            playbackSessionLogger.error("Could not read playback session: \(error.localizedDescription)")
            return
        }
        guard let snapshot = stored else { return }
        openTracks = snapshot.openTracks.filter { Track.accepts($0.url) }
        let known = Dictionary((playlists.flatMap(\.tracks) + folders.flatMap(\.tracks) + openTracks)
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = snapshot.queue.map { known[$0.id] ?? $0 }.filter { Track.accepts($0.url) }
        playbackSource = snapshot.source
        librarySectionStart = snapshot.librarySection
        if case .container(let id) = playbackSource {
            if tracks(in: id) == nil { playbackSource = .snapshot }
            else { selectedID = id }
        }

        let original = known[snapshot.current.id] ?? snapshot.current
        // Если файл исчез, пробуем ближайший следующий, затем предыдущий.
        let index = queue.firstIndex { $0.id == original.id }
        let tail = index.map { queue.suffix(from: $0 + 1) } ?? queue[...]
        let head = index.map { queue.prefix(upTo: $0) } ?? []
        for track in [original] + tail + head.reversed() {
            guard let info = try? engine.load(resolvedURL(of: track)) else { continue }
            if shuffleEnabled {
                if track.id == original.id, let savedOrder = snapshot.shuffleOrder {
                    shuffleOrder = savedOrder
                    shuffleOrder.update(queue.map(\.id), current: track.id)
                } else {
                    shuffleOrder.reset(queue.map(\.id), startingAt: track.id)
                }
            }
            setNowPlaying(track, info: info)
            configureAudio()
            let storedPosition = track.id == original.id && snapshot.position.isFinite ? snapshot.position : 0
            seek(storedPosition)
            return
        }
    }

    // MARK: События AudioEngine

    /// Аудиоустройство пропало, и продолжить воспроизведение не удалось.
    func playbackLost(_ cause: Error) {
        let track = current
        stop()
        error = track.map { strings.errorPlay($0.title, AudioDecoding.message(cause, strings: strings)) }
            ?? strings.errorAudioDevice
    }

    func configureAudio() {
        if let current = current { engine.configurePlayback(audioPlan(for: current)) }
    }

    func trackTransitioned(_ boundary: AudioStreamBoundary, position: Double) {
        guard let previous = current else { return }
        if playing { sampleListening(at: duration) }
        listeningSession = ListeningSession()
        if shuffleEnabled && repeatMode != .track {
            _ = shuffleOrder.advance(from: previous.id, repeatingQueue: false)
        }
        setNowPlaying(boundary.item.track, info: boundary.info)
        self.position = position
        if playing { resumeListening(at: position) }
        engine.replenish(audioPlan(for: boundary.item.track), after: boundary.ordinal)
    }

    private func audioPlan(for track: Track) -> AudioStreamPlan {
        var upcoming: [Track] = []
        if audioOptions.usesTransitions {
            if repeatMode == .track, queue.contains(where: { $0.id == track.id }) {
                upcoming = Array(repeating: track, count: 8)
            } else if shuffleEnabled {
                var preview = shuffleOrder
                var id = track.id
                for _ in 0..<8 {
                    // Следующий случайный цикл создаётся только обычным переходом.
                    guard let next = preview.advance(from: id, repeatingQueue: false),
                          let item = queue.first(where: { $0.id == next }) else { break }
                    upcoming.append(item)
                    id = next
                }
            } else if !queue.isEmpty {
                let start = queue.firstIndex { $0.id == track.id }.map { $0 + 1 } ?? 0
                for index in start..<(start + 8) {
                    if index >= queue.count && repeatMode != .queue { break }
                    upcoming.append(queue[index % queue.count])
                }
            }
        }
        func item(_ track: Track) -> AudioStreamItem {
            AudioStreamItem(track: track, cachedGain: audioOptions.replayGain == .off ? nil : gainStore.values(for: track))
        }
        return AudioStreamPlan(current: item(track), upcoming: upcoming.map(item), options: audioOptions,
                               equalizer: audioOptions.replayGain == .off ? EqualizerSettings() : equalizer)
    }

    private func setNowPlaying(_ track: Track, info: AudioEngine.Info) {
        currentBitrate = info.bitrate
        currentSampleRate = info.sampleRate
        currentChannels = info.channels
        current = track
        duration = info.duration
    }

    // MARK: Внутреннее

    private func startQueue(_ tracks: [Track], at track: Track) {
        queue = tracks
        if shuffleEnabled { shuffleOrder.reset(queue.map(\.id), startingAt: track.id) }
        startTrack(track)
    }

    /// Смена файла не сбрасывает историю переходов внутри очереди.
    private func startTrack(_ track: Track) {
        clearPlaybackState()
        do {
            let info = try engine.load(try resolvedURL(of: track))
            setNowPlaying(track, info: info)
            configureAudio()
            guard engine.play() else { throw NSError(domain: "VibeWave", code: 1, userInfo: [NSLocalizedDescriptionKey: strings.errorAudioDevice]) }
            playing = true
            resumeListening(at: engine.currentTime)
            startTimer()
        } catch {
            stop()
            self.error = strings.errorPlay(track.title, AudioDecoding.message(error, strings: strings))
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
            self.sampleListening(at: self.position)
        }
    }
}

private let playbackSessionLogger = Logger(subsystem: "local.vibewave.player", category: "playback-session")
