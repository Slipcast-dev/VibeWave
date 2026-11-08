import AppKit
import AVFoundation
import Combine
import VibeWaveCore
import UniformTypeIdentifiers

/// Строка общего списка: трек и источник, к которому относятся действия с ним.
struct LibraryEntry: Identifiable {
    let track: Track
    let sourceID: UUID?
    var id: UUID { track.id }
}

/// Раздел режима «По плейлистам»: плейлист, папка или музыка вне плейлистов (id == nil).
struct LibrarySection: Identifiable {
    enum Kind { case playlist, folder, loose }
    let sourceID: UUID?
    let kind: Kind
    let title: String
    let tracks: [Track]
    var id: String { sourceID?.uuidString ?? "loose" }
}

/// Откуда строится очередь: конкретный источник или общий список «Вся музыка».
enum PlaybackSource: Equatable {
    case container(UUID?)
    case library
}

/// Управляет воспроизведением и библиотекой на главном потоке интерфейса.
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playlists: [Playlist] = []
    @Published var folders: [MusicFolder] = []
    /// Ручной порядок раздела «Вся музыка» без группировки.
    @Published private(set) var libraryOrder: [UUID] = []
    /// Группировка общего списка по плейлистам и папкам; влияет и на очередь.
    @Published var groupByPlaylists = UserDefaults.standard.bool(forKey: "library.grouped") {
        didSet {
            UserDefaults.standard.set(groupByPlaylists, forKey: "library.grouped")
            if playbackSource == .library { refreshPlaybackQueue() }
        }
    }
    /// nil — раздел «Вся музыка»; иначе ID плейлиста или папки.
    @Published var selectedID: UUID?
    @Published var openTracks: [Track] = []
    @Published var current: Track?
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.75 {
        didSet { player?.volume = Float(volume) }
    }
    /// Баланс каналов: -1 левый, 0 центр, 1 правый.
    @Published var balance: Double = 0 {
        didSet { player?.pan = Float(balance) }
    }
    /// Сведения о текущем файле для ЖК-панели.
    @Published private(set) var currentBitrate = 0
    @Published private(set) var currentSampleRate = 0.0
    @Published private(set) var currentChannels = 0
    @Published var error: String?
    @Published var importing = false

    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?
    private var queue: [Track] = []
    private var playbackSource: PlaybackSource = .container(nil)
    private var librarySectionStart: String?
    private var accessedURL: URL?
    private let store: LibraryStore
    // После ошибки чтения не перезаписываем повреждённую библиотеку молча.
    private var canSave = true

    var selected: Playlist? { playlists.first { $0.id == selectedID } }
    var selectedFolder: MusicFolder? { folders.first { $0.id == selectedID } }
    var isLibrarySelected: Bool { selectedID == nil || (selected == nil && selectedFolder == nil) }
    var selectedTitle: String { selected?.name ?? selectedFolder?.name ?? "Вся музыка" }
    var visibleTracks: [Track] {
        if let playlist = selected { return playlist.tracks }
        if let folder = selectedFolder { return folder.tracks }
        return libraryQueueTracks
    }

    func isFolder(_ id: UUID?) -> Bool { id.map { id in folders.contains { $0.id == id } } ?? false }
    func isPlaylist(_ id: UUID?) -> Bool { id.map { id in playlists.contains { $0.id == id } } ?? false }

    /// Все уникальные файлы библиотеки в ручном порядке.
    var libraryEntries: [LibraryEntry] {
        var seenIDs = Set<UUID>()
        var seenURLs = Set<URL>()
        var entries: [LibraryEntry] = []
        func add(_ tracks: [Track], from source: UUID?) {
            for track in tracks where seenIDs.insert(track.id).inserted && seenURLs.insert(track.url.standardizedFileURL).inserted {
                entries.append(LibraryEntry(track: track, sourceID: source))
            }
        }
        add(openTracks, from: nil)
        for playlist in playlists { add(playlist.tracks, from: playlist.id) }
        for folder in folders { add(folder.tracks, from: folder.id) }
        return ManualOrder.arrange(entries, order: libraryOrder, id: \.id)
    }

    var librarySections: [LibrarySection] {
        playlists.map { LibrarySection(sourceID: $0.id, kind: .playlist, title: $0.name, tracks: $0.tracks) }
            + folders.map { LibrarySection(sourceID: $0.id, kind: .folder, title: $0.name, tracks: $0.tracks) }
            + [LibrarySection(sourceID: nil, kind: .loose, title: "Вне плейлистов", tracks: openTracks)]
    }

    /// Очередь раздела «Вся музыка» совпадает с тем, что видно на экране.
    var libraryQueueTracks: [Track] { libraryQueue(startingSection: nil) }

    /// В режиме «По плейлистам» очередь начинается с раздела, где запущен трек:
    /// копия трека в другом плейлисте не подменяет его соседей.
    private func libraryQueue(startingSection: String?) -> [Track] {
        guard groupByPlaylists else { return libraryEntries.map(\.track) }
        var sections = librarySections
        if let start = startingSection, let index = sections.firstIndex(where: { $0.id == start }) {
            sections = Array(sections[index...] + sections[..<index])
        }
        var seen = Set<UUID>()
        return sections.flatMap(\.tracks).filter { seen.insert($0.id).inserted }
    }
    var nextTrack: Track? {
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }), index + 1 < queue.count else { return nil }
        return queue[index + 1]
    }

    func tracks(in sourceID: UUID?) -> [Track]? {
        guard let id = sourceID else { return openTracks }
        return playlists.first(where: { $0.id == id })?.tracks ?? folders.first(where: { $0.id == id })?.tracks
    }

    /// Временная очередь, плейлисты и папки обновляются раздельно.
    private func replaceTracks(_ tracks: [Track], in sourceID: UUID?) {
        if let id = sourceID {
            if let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index].tracks = tracks }
            else if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].tracks = tracks }
        } else { openTracks = tracks }
    }

    private var playbackTracks: [Track]? {
        switch playbackSource {
        case .library: return libraryQueue(startingSection: librarySectionStart)
        case .container(let id): return tracks(in: id)
        }
    }

    private func refreshPlaybackQueue() {
        guard current != nil, let tracks = playbackTracks else { return }
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
                let snapshot = try store.loadSnapshot()
                playlists = snapshot.playlists
                folders = snapshot.folders
                libraryOrder = snapshot.order
            }
            selectedID = nil
        } catch {
            canSave = false
            self.error = "Не удалось прочитать библиотеку. Файл сохранён без изменений. \(error.localizedDescription)"
        }
    }

    func save() {
        guard canSave else { return }
        // Временные треки вне плейлистов не сохраняются, поэтому их нет и в порядке.
        let persistent = Set(playlists.flatMap(\.tracks).map(\.id) + folders.flatMap(\.tracks).map(\.id))
        do { try store.save(LibrarySnapshot(playlists: playlists, folders: folders, order: libraryOrder.filter(persistent.contains))) }
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

    func removeTrack(_ id: UUID) { removeTrack(id, from: selectedID) }

    /// Явный источник нужен для постоянного списка очереди при просмотре плейлиста.
    func removeTrack(_ id: UUID, from sourceID: UUID?) {
        guard var tracks = tracks(in: sourceID) else { return }
        tracks.removeAll { $0.id == id }
        replaceTracks(tracks, in: sourceID)
        if current?.id == id, playbackTracks?.contains(where: { $0.id == id }) != true { stop() }
        else { refreshPlaybackQueue() }
        if sourceID != nil { save() }
    }

    /// Перестановка в общем списке «Вся музыка» без группировки.
    func moveInLibrary(_ id: UUID, before destination: UUID?) {
        guard let order = ManualOrder.move(id, before: destination, in: libraryEntries.map(\.id)) else { return }
        libraryOrder = order
        refreshPlaybackQueue()
        save()
    }

    func moveInLibraryBy(_ id: UUID, offset: Int) {
        let ids = libraryEntries.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset), offset != 0 else { return }
        let target = index + offset
        moveInLibrary(id, before: offset < 0 ? ids[target] : (target + 1 < ids.count ? ids[target + 1] : nil))
    }

    /// section — ID раздела режима «По плейлистам», из которого запущен трек.
    func playLibrary(_ track: Track, section: String? = nil) {
        librarySectionStart = groupByPlaylists ? section : nil
        queue = libraryQueue(startingSection: librarySectionStart)
        playbackSource = .library
        startTrack(track)
    }

    func moveTrackBy(_ id: UUID, in sourceID: UUID?, offset: Int) {
        guard let tracks = tracks(in: sourceID), let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard tracks.indices.contains(target), target != index else { return }
        let destination = offset < 0 ? tracks[target].id : (target + 1 < tracks.count ? tracks[target + 1].id : nil)
        moveTrack(TrackDragPayload(playlistID: sourceID, trackID: id), to: sourceID, before: destination)
    }

    /// Кнопка добавляет в выбранный пользователем раздел: очередь или плейлист.
    func importFiles() {
        guard !importing else { return }
        let targetID = isPlaylist(selectedID) ? selectedID : nil
        let panel = NSOpenPanel()
        panel.title = targetID == nil ? "Добавить музыку вне плейлистов" : "Добавить музыку в плейлист"
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
    /// Папки из Finder добавляются как папки библиотеки; файлы в папку не перетаскиваются.
    func receiveFiles(_ urls: [URL], into playlistID: UUID? = nil, before destination: UUID? = nil) {
        guard !importing else { error = "Дождитесь завершения текущего добавления файлов."; return }
        let directories = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if !directories.isEmpty { addFolders(directories); return }
        importURLs(urls, into: isFolder(playlistID) ? nil : playlistID, before: destination)
    }

    // MARK: Папки

    func chooseFolder() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "Добавить папку с музыкой"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    func addFolders(_ urls: [URL]) {
        guard !importing else { error = "Дождитесь завершения текущего добавления файлов."; return }
        let fresh = urls.filter { url in !folders.contains { $0.url.standardizedFileURL == url.standardizedFileURL } }
        guard !fresh.isEmpty else { error = "Эта папка уже добавлена."; return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = fresh.map { url -> (MusicFolder?, [String]) in
                let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                guard let (tracks, failures) = Self.scan(folder: url) else { return (nil, ["папка «\(url.lastPathComponent)» недоступна"]) }
                return (MusicFolder(url: url, bookmark: bookmark, tracks: tracks), failures)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.importing = false
                let added = scanned.compactMap(\.0)
                self.folders += added
                if let first = added.first { self.selectedID = first.id }
                self.save()
                let failures = scanned.flatMap(\.1)
                if !failures.isEmpty { self.error = "Не удалось открыть: " + failures.joined(separator: ", ") }
            }
        }
    }

    func rescanFolder(_ id: UUID) {
        guard !importing, let folder = folders.first(where: { $0.id == id }) else { return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.scan(folder: folder.url, bookmark: folder.bookmark)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.importing = false
                // Недоступная папка не очищается: список треков и их порядок сохраняются.
                guard let (tracks, failures) = result else {
                    self.error = "Папка «\(folder.name)» недоступна. Подключите диск и повторите обновление."
                    return
                }
                guard let index = self.folders.firstIndex(where: { $0.id == id }) else { return }
                self.folders[index].merge(scanned: tracks)
                self.refreshPlaybackQueue()
                self.save()
                if !failures.isEmpty { self.error = "Не удалось открыть: " + failures.joined(separator: ", ") }
            }
        }
    }

    func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        if let current = current, playbackTracks?.contains(where: { $0.id == current.id }) != true { stop() }
        else { refreshPlaybackQueue() }
        save()
    }

    /// Рекурсивный поиск MP3/FLAC; файлы сортируются как в Finder.
    /// nil — папка недоступна (отключён диск, нет прав): это не то же самое, что пустая папка.
    private static func scan(folder: URL, bookmark: Data? = nil) -> ([Track], [String])? {
        var root = folder
        if let data = bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) { root = resolved }
        }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return nil }
        let files = enumerator.compactMap { $0 as? URL }
            .filter(Track.accepts)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var tracks: [Track] = []
        var failures: [String] = []
        for url in files {
            do {
                let audio = try AVAudioPlayer(contentsOf: url)
                let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                tracks.append(Track(url: url, duration: audio.duration, bookmark: bookmark))
            } catch { failures.append(url.lastPathComponent) }
        }
        return (tracks, failures)
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
    /// Из очереди и папок трек копируется; в папку извне ничего не добавляется.
    func moveTrack(_ payload: TrackDragPayload, to targetID: UUID?, before destination: UUID?) {
        guard payload.playlistID == targetID || !isFolder(targetID),
              var source = tracks(in: payload.playlistID),
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
            let movingBetweenPlaylists = isPlaylist(payload.playlistID) && isPlaylist(targetID)
            if movingBetweenPlaylists {
                source.removeAll { $0.id == track.id }
                replaceTracks(source, in: payload.playlistID)
            }
            let index = destination.flatMap { id in target.firstIndex { $0.id == id } } ?? target.endIndex
            target.insert(track, at: index)
            replaceTracks(target, in: targetID)
            if movingBetweenPlaylists && playbackSource == .container(payload.playlistID) && current?.id == track.id {
                playbackSource = .container(targetID)
            }
        }
        refreshPlaybackQueue()
        if payload.playlistID != nil || targetID != nil { save() }
    }

    func play(_ track: Track, in tracks: [Track], playlistID: UUID? = nil) {
        queue = tracks
        playbackSource = .container(playlistID)
        startTrack(track)
    }

    /// Переход вперёд/назад идёт по текущей очереди.
    private func startTrack(_ track: Track) {
        stop()
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
                    for index in folders.indices {
                        if let row = folders[index].tracks.firstIndex(where: { $0.id == track.id }) {
                            folders[index].tracks[row].bookmark = fresh
                            folders[index].tracks[row].url = resolved
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
            audio.pan = Float(balance)
            audio.isMeteringEnabled = true
            player = audio
            let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            currentBitrate = audio.duration > 0 ? Int((Double(size) * 8 / audio.duration / 1000).rounded()) : 0
            currentSampleRate = audio.format.sampleRate
            currentChannels = Int(audio.format.channelCount)
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
            let tracks = visibleTracks
            guard let first = tracks.first else { return }
            if isLibrarySelected { playLibrary(first) } else { play(first, in: tracks, playlistID: selectedID) }
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
        if let next = nextTrack { startTrack(next) } else { stop() }
    }

    /// Уровни левого и правого канала 0…1 для индикатора; без воспроизведения — нули.
    func meterLevels() -> (Double, Double) {
        guard let player = player, playing else { return (0, 0) }
        player.updateMeters()
        func level(_ channel: Int) -> Double {
            let power = Double(player.averagePower(forChannel: min(channel, player.numberOfChannels - 1)))
            return power.isFinite ? max(0, min(1, (power + 50) / 50)) : 0
        }
        return (level(0), level(1))
    }

    func previous() {
        if position > 3 { seek(0); return }
        guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        startTrack(queue[max(0, index - 1)])
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
        currentBitrate = 0
        currentSampleRate = 0
        currentChannels = 0
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
