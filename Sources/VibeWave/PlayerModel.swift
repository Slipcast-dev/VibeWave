import Combine
import Foundation
import VibeWaveCore

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

/// Состояние плеера и библиотеки для SwiftUI. Всё состояние живёт на главном потоке,
/// фоновые задачи возвращают результаты через DispatchQueue.main.
///
/// Части модели разнесены по файлам:
/// - `PlayerModel.swift` — состояние, загрузка/сохранение, производные списки;
/// - `PlayerModel+Library.swift` — плейлисты, папки и перестановка треков;
/// - `PlayerModel+Import.swift` — добавление файлов и папок, прогресс и отмена;
/// - `PlayerModel+Playback.swift` — очередь воспроизведения и управление `AudioEngine`.
@MainActor
final class PlayerModel: NSObject, ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var folders: [MusicFolder] = []
    /// Ручной порядок раздела «Вся музыка» без группировки.
    @Published var libraryOrder: [UUID] = []
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
        didSet { engine.volume = Float(volume) }
    }
    /// Баланс каналов: -1 левый, 0 центр, 1 правый.
    @Published var balance: Double = 0 {
        didSet { engine.pan = Float(balance) }
    }
    /// Сведения о текущем файле для ЖК-панели.
    @Published var currentBitrate = 0
    @Published var currentSampleRate = 0.0
    @Published var currentChannels = 0
    @Published var error: String?
    /// Идёт фоновое добавление или сканирование; одновременно выполняется одна задача.
    @Published var importing = false
    @Published var importProgress: ImportProgress?

    let engine: AudioEngine
    var importJob: ImportJob?
    var timer: AnyCancellable?
    var queue: [Track] = []
    var playbackSource: PlaybackSource = .container(nil)
    var librarySectionStart: String?
    private let store: LibraryStore
    // После ошибки чтения не перезаписываем повреждённую библиотеку молча.
    private var canSave = true

    override convenience init() {
        self.init(supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Отдельный каталог позволяет проверять переносы и миграцию, не трогая библиотеку пользователя.
    init(supportDirectory support: URL) {
        store = LibraryStore(url: support.appendingPathComponent("VibeWave/library.json"))
        engine = AudioEngine()
        super.init()
        engine.volume = Float(volume)
        engine.onFinish = { [weak self] flag in self?.trackFinished(successfully: flag) }
        engine.onDecodeError = { [weak self] error in self?.decodeFailed(error) }
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

    // MARK: Выбор и производные списки

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
    func libraryQueue(startingSection: String?) -> [Track] {
        guard groupByPlaylists else { return libraryEntries.map(\.track) }
        var sections = librarySections
        if let start = startingSection, let index = sections.firstIndex(where: { $0.id == start }) {
            sections = Array(sections[index...] + sections[..<index])
        }
        var seen = Set<UUID>()
        return sections.flatMap(\.tracks).filter { seen.insert($0.id).inserted }
    }

    // MARK: Источники

    func tracks(in sourceID: UUID?) -> [Track]? {
        guard let id = sourceID else { return openTracks }
        return playlists.first(where: { $0.id == id })?.tracks ?? folders.first(where: { $0.id == id })?.tracks
    }

    /// Временная очередь, плейлисты и папки обновляются раздельно.
    func replaceTracks(_ tracks: [Track], in sourceID: UUID?) {
        if let id = sourceID {
            if let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index].tracks = tracks }
            else if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].tracks = tracks }
        } else { openTracks = tracks }
    }
}
