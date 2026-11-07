import AppKit
import AVFoundation
import Combine
import VibeWaveCore
import UniformTypeIdentifiers

/// Управляет воспроизведением и библиотекой на главном потоке интерфейса.
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playlists: [Playlist] = []
    /// nil означает просмотр временной очереди, которая не сохраняется как плейлист.
    @Published var selectedID: UUID?
    @Published var openTracks: [Track] = []
    @Published var current: Track?
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.75 {
        didSet { player?.volume = Float(volume) }
    }
    @Published var error: String?
    @Published var importing = false

    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?
    private var queue: [Track] = []
    private var playbackPlaylistID: UUID?
    private var accessedURL: URL?
    private let store: LibraryStore
    // После ошибки чтения не перезаписываем повреждённую библиотеку молча.
    private var canSave = true

    var selected: Playlist? { playlists.first { $0.id == selectedID } }
    var visibleTracks: [Track] { selected?.tracks ?? openTracks }

    private func tracks(in playlistID: UUID?) -> [Track]? {
        guard let id = playlistID else { return openTracks }
        return playlists.first(where: { $0.id == id })?.tracks
    }

    /// Временная очередь и сохранённые плейлисты обновляются раздельно.
    private func replaceTracks(_ tracks: [Track], in playlistID: UUID?) {
        if let id = playlistID {
            guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
            playlists[index].tracks = tracks
        } else { openTracks = tracks }
    }

    private func refreshPlaybackQueue() {
        guard current != nil, let tracks = tracks(in: playbackPlaylistID) else { return }
        queue = tracks
    }

    override convenience init() {
        self.init(supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Отдельный каталог позволяет проверять переносы и миграцию, не трогая библиотеку пользователя.
    init(supportDirectory support: URL) {
        store = LibraryStore(url: support.appendingPathComponent("VibeWave/library.json"))
        super.init()
        do {
            // При первом запуске нового имени читаем прежнюю библиотеку без её удаления.
            if !FileManager.default.fileExists(atPath: store.url.path) {
                let legacy = LibraryStore(url: support.appendingPathComponent("Tiho/library.json"))
                playlists = try legacy.load()
                if !playlists.isEmpty { try store.save(playlists) }
            } else {
                playlists = try store.load()
            }
            selectedID = nil
        } catch {
            canSave = false
            self.error = "Не удалось прочитать библиотеку. Файл сохранён без изменений. \(error.localizedDescription)"
        }
    }

    func save() {
        guard canSave else { return }
        do { try store.save(playlists) }
        catch { self.error = "Не удалось сохранить плейлисты: \(error.localizedDescription)" }
    }

    func createPlaylist(_ name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let playlist = Playlist(name: value)
        playlists.append(playlist)
        selectedID = playlist.id
        save()
    }

    func renamePlaylist(_ id: UUID, name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = value
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        save()
    }

    func removeTrack(_ id: UUID) {
        guard var tracks = tracks(in: selectedID) else { return }
        tracks.removeAll { $0.id == id }
        replaceTracks(tracks, in: selectedID)
        if playbackPlaylistID == selectedID {
            queue = tracks
            if current?.id == id { stop() }
        }
        if selectedID != nil { save() }
    }

    /// Кнопка добавляет в выбранный пользователем раздел: очередь или плейлист.
    func importFiles() {
        guard !importing else { return }
        let targetID = selectedID
        let panel = NSOpenPanel()
        panel.title = targetID == nil ? "Открыть музыку вне плейлистов" : "Добавить музыку в плейлист"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mp3"), UTType(filenameExtension: "flac")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        receiveFiles(panel.urls, into: targetID)
    }

    /// Открытие через Finder или Dock всегда относится к очереди вне плейлистов,
    /// даже если перед этим пользователь просматривал сохранённый плейлист.
    func openFiles(_ urls: [URL]) {
        guard !importing else { error = "Дождитесь завершения текущего добавления файлов."; return }
        selectedID = nil
        importURLs(urls, into: nil, autoplay: true)
    }

    /// nil — очередь. Отсутствующий или удалённый плейлист не создаётся заново.
    func receiveFiles(_ urls: [URL], into playlistID: UUID? = nil, before destination: UUID? = nil) {
        guard !importing else { error = "Дождитесь завершения текущего добавления файлов."; return }
        importURLs(urls, into: playlistID, before: destination)
    }

    /// Общий путь импорта: декодирование выполняется последовательно в фоне,
    /// а назначение фиксируется до начала работы и не зависит от переключения раздела.
    func importURLs(_ urls: [URL], into targetID: UUID?, before destination: UUID? = nil, autoplay: Bool = false) {
        guard !importing else { return }
        guard tracks(in: targetID) != nil else { error = "Плейлист больше не существует."; return }
        let supported = urls.filter(Track.accepts)
        guard !supported.isEmpty else { error = "Добавьте локальные файлы MP3 или FLAC."; return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var imported: [Track] = []
            var failures: [String] = []
            for url in supported {
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let audio = try AVAudioPlayer(contentsOf: url)
                    // В локальной сборке app-scope key может отсутствовать.
                    // Необязательная закладка не должна отклонять исправную музыку.
                    let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    imported.append(Track(url: url, duration: audio.duration, bookmark: bookmark))
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.importing = false
                guard var tracks = self.tracks(in: targetID) else {
                    self.error = "Плейлист был удалён во время добавления файлов."
                    return
                }
                for track in imported {
                    guard !tracks.contains(where: { $0.url.standardizedFileURL == track.url.standardizedFileURL }) else { continue }
                    let insertion = destination.flatMap { id in tracks.firstIndex { $0.id == id } } ?? tracks.endIndex
                    tracks.insert(track, at: insertion)
                }
                self.replaceTracks(tracks, in: targetID)
                self.refreshPlaybackQueue()
                if targetID != nil { self.save() }
                if autoplay, let firstURL = imported.first?.url,
                   let first = tracks.first(where: { $0.url.standardizedFileURL == firstURL.standardizedFileURL }) {
                    self.play(first, in: tracks, playlistID: targetID)
                }
                if !failures.isEmpty { self.error = "Не удалось открыть: " + failures.joined(separator: ", ") }
            }
        }
    }

    /// Внутри одного раздела меняется порядок. Между плейлистами трек переносится.
    /// При добавлении из временной очереди оригинальная очередь сохраняется.
    func moveTrack(_ payload: TrackDragPayload, to targetID: UUID?, before destination: UUID?) {
        guard var source = tracks(in: payload.playlistID),
              var target = tracks(in: targetID),
              let track = source.first(where: { $0.id == payload.trackID }),
              destination == nil || target.contains(where: { $0.id == destination }) else { return }
        if payload.playlistID == targetID {
            guard track.id != destination else { return }
            source.removeAll { $0.id == track.id }
            let index = destination.flatMap { id in source.firstIndex { $0.id == id } } ?? source.endIndex
            source.insert(track, at: index)
            replaceTracks(source, in: targetID)
        } else {
            guard !target.contains(where: { $0.url.standardizedFileURL == track.url.standardizedFileURL }) else { return }
            // Сохранённые плейлисты не теряют записи при копировании в очередь.
            let movingBetweenPlaylists = payload.playlistID != nil && targetID != nil
            if movingBetweenPlaylists {
                source.removeAll { $0.id == track.id }
                replaceTracks(source, in: payload.playlistID)
            }
            let index = destination.flatMap { id in target.firstIndex { $0.id == id } } ?? target.endIndex
            target.insert(track, at: index)
            replaceTracks(target, in: targetID)
            if movingBetweenPlaylists && playbackPlaylistID == payload.playlistID && current?.id == track.id {
                playbackPlaylistID = targetID
            }
        }
        refreshPlaybackQueue()
        if payload.playlistID != nil || targetID != nil { save() }
    }

    func play(_ track: Track, in tracks: [Track], playlistID: UUID? = nil) {
        stop()
        queue = tracks
        playbackPlaylistID = playlistID
        do {
            var resolved = track.url
            if let data = track.bookmark {
                var stale = false
                resolved = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                // Пересоздаём устаревшую закладку, сохраняя доступ после перемещения файла.
                if stale {
                    let scoped = resolved.startAccessingSecurityScopedResource()
                    defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
                    let fresh = try resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    for index in playlists.indices {
                        if let row = playlists[index].tracks.firstIndex(where: { $0.id == track.id }) {
                            playlists[index].tracks[row].bookmark = fresh
                            playlists[index].tracks[row].url = resolved
                        }
                    }
                    if let row = openTracks.firstIndex(where: { $0.id == track.id }) {
                        openTracks[row].bookmark = fresh
                        openTracks[row].url = resolved
                    }
                    save()
                }
            }
            if resolved.startAccessingSecurityScopedResource() { accessedURL = resolved }
            let audio = try AVAudioPlayer(contentsOf: resolved)
            audio.delegate = self
            audio.volume = Float(volume)
            player = audio
            guard audio.play() else { throw NSError(domain: "VibeWave", code: 1, userInfo: [NSLocalizedDescriptionKey: "Аудиоустройство недоступно."]) }
            current = track
            duration = audio.duration
            playing = true
            startTimer()
        } catch {
            stop()
            self.error = "Не удалось воспроизвести «\(track.title)»: \(error.localizedDescription)"
        }
    }

    func toggle() {
        guard let player = player else {
            if let first = visibleTracks.first { play(first, in: visibleTracks, playlistID: selectedID) }
            return
        }
        if playing {
            player.pause()
            timer = nil
            playing = false
        } else {
            guard player.play() else { error = "Не удалось продолжить воспроизведение."; return }
            playing = true
            startTimer()
        }
    }

    private func startTimer() {
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self else { return }
            self.position = self.player?.currentTime ?? 0
        }
    }

    func seek(_ value: Double) {
        let target = max(0, min(value, duration))
        player?.currentTime = target
        position = target
    }

    func next() {
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }), index + 1 < queue.count else { stop(); return }
        play(queue[index + 1], in: queue, playlistID: playbackPlaylistID)
    }

    func previous() {
        if position > 3 { seek(0); return }
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        play(queue[max(0, index - 1)], in: queue, playlistID: playbackPlaylistID)
    }

    func stop() {
        timer = nil
        player?.stop()
        player = nil
        if let url = accessedURL { url.stopAccessingSecurityScopedResource() }
        accessedURL = nil
        playing = false
        current = nil
        position = 0
        duration = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { next() }
        else { stop(); error = "Файл не удалось воспроизвести до конца." }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stop()
        self.error = "Ошибка декодирования: \(error?.localizedDescription ?? "повреждённый файл")"
    }
}
