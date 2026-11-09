import Foundation

/// Язык интерфейса. Названия языков в меню пишутся на самом языке.
public enum AppLanguage: String, CaseIterable, Sendable {
    case ru, en

    /// Название языка для меню выбора («Русский», «English»).
    public var nativeName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// Короткая подпись кнопки в нижней панели.
    public var code: String { rawValue.uppercased() }

    /// Первый поддерживаемый язык из списка предпочтений системы
    /// (`Locale.preferredLanguages`, например ["de-DE", "ru-RU"]). Если ни русского,
    /// ни английского в списке нет, используется английский.
    public static func preferred(from languages: [String]) -> AppLanguage {
        for identifier in languages {
            let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let code = code, let language = AppLanguage(rawValue: code) { return language }
        }
        return .en
    }
}

/// Выбор пользователя: язык системы или конкретный язык.
public enum LanguagePreference: String, CaseIterable, Sendable {
    case system, ru, en

    public func resolve(systemLanguages: [String]) -> AppLanguage {
        switch self {
        case .system: return AppLanguage.preferred(from: systemLanguages)
        case .ru: return .ru
        case .en: return .en
        }
    }
}

/// Все строки интерфейса. Каждый язык — полный экземпляр структуры,
/// поэтому пропущенный перевод не скомпилируется.
public struct Strings: Sendable {
    // Меню приложения
    public let menuAbout: String
    public let menuQuit: String
    public let menuFile: String
    public let menuAddFiles: String
    public let menuEdit: String
    public let menuUndo: String
    public let menuCut: String
    public let menuCopy: String
    public let menuPaste: String
    public let menuSelectAll: String
    public let menuWindow: String
    public let minimize: String
    public let zoom: String
    public let closeWindow: String
    public let titleBar: String

    // Диалоги и сообщения
    public let newPlaylist: String
    public let playlistName: String
    public let namePlaceholder: String
    public let cancel: String
    public let save: String
    public let ok: String

    // Библиотека
    public let allMusic: String
    public let playlists: String
    public let createPlaylist: String
    public let noPlaylists: String
    public let rename: String
    public let deletePlaylist: String
    public let folders: String
    public let addMusicFolder: String
    public let noFolders: String
    public let refreshFolder: String
    public let showInFinder: String
    public let removeFromLibrary: String
    public let outsidePlaylists: String

    // Нижняя панель
    public let playlistLabel: String
    public let addFileButton: String
    public let addFilesHelp: String
    public let addFolderButton: String
    public let libraryButton: String
    public let libraryHelp: String
    public let cancelImportHelp: String
    public let counterHelp: String
    public let viewMenu: String
    public let flatList: String
    public let groupedList: String
    public let newPlaylistMenu: String
    public let viewHelp: String
    public let languageHelp: String
    public let languageSystem: @Sendable (String) -> String

    // Панель плеера
    public let volume: String
    public let balanceShort: String
    public let balance: String
    public let balanceHelp: String
    public let position: String
    public let timeHelp: String
    public let idleMarquee: String
    public let mono: String
    public let stereo: String
    public let previousTrack: String
    public let play: String
    public let pause: String
    public let stop: String
    public let nextTrack: @Sendable (String) -> String
    public let endOfQueue: String
    public let percent: @Sendable (Int) -> String

    // Эквалайзер
    public let eqHelp: String
    public let eqTitle: String
    public let eqOn: String
    public let eqOnHelp: String
    public let eqPresets: String
    public let eqCustom: String
    public let eqReset: String
    public let eqResetHelp: String
    public let eqPreamp: String
    public let eqPresetName: @Sendable (EqualizerPreset) -> String
    /// Доступное имя ползунка полосы по подписи частоты («1K»).
    public let eqBand: @Sendable (String) -> String
    public let eqDecibels: @Sendable (Float) -> String

    // Список треков
    public let trackHelp: @Sendable (String) -> String
    public let source: @Sendable (String) -> String
    public let moveUp: String
    public let moveDown: String
    public let moveToPlaylist: String
    public let addToPlaylist: String
    public let removeFromPlaylist: String
    public let hideFromFolder: String
    public let removeFromList: String
    public let emptyPlaylist: String
    public let emptyFolder: String
    public let emptyLibrary: String
    public let emptyHint: String

    // Импорт
    public let panelAddOutside: String
    public let panelAddToPlaylist: String
    public let progressFiles: String
    public let progressFolder: @Sendable (String) -> String
    public let progressFolders: @Sendable (Int) -> String
    public let progressSearching: @Sendable (String) -> String
    public let progressCount: @Sendable (String, Int, Int) -> String

    // Ошибки
    public let errorImportBusy: String
    public let errorFolderAlreadyAdded: String
    public let errorFolderUnavailableShort: @Sendable (String) -> String
    public let errorFolderUnavailable: @Sendable (String) -> String
    public let errorPlaylistGone: String
    public let errorNoSupportedFiles: String
    public let errorPlaylistDeletedDuringImport: String
    /// (первые имена, сколько ещё не показано)
    public let errorCouldNotOpen: @Sendable ([String], Int) -> String
    public let errorLibraryRead: @Sendable (String) -> String
    public let errorLibrarySave: @Sendable (String) -> String
    public let errorResume: String
    public let errorAudioDevice: String
    public let errorPlay: @Sendable (String, String) -> String
    public let errorDragRead: String

    // Обновление
    public let updateTitle: String
    /// (новая версия, текущая версия)
    public let updateMessage: @Sendable (String, String) -> String
    public let updateNow: String
    public let updateLater: String
    public let updateVerificationFailed: @Sendable (String) -> String

    public static func `for`(_ language: AppLanguage) -> Strings {
        switch language {
        case .ru: return .ru
        case .en: return .en
        }
    }

    public static let ru = Strings(
        menuAbout: "О VibeWave",
        menuQuit: "Завершить VibeWave",
        menuFile: "Файл",
        menuAddFiles: "Добавить файлы…",
        menuEdit: "Правка",
        menuUndo: "Отменить",
        menuCut: "Вырезать",
        menuCopy: "Копировать",
        menuPaste: "Вставить",
        menuSelectAll: "Выделить всё",
        menuWindow: "Окно",
        minimize: "Свернуть",
        zoom: "Развернуть или восстановить",
        closeWindow: "Закрыть окно",
        titleBar: "Заголовок окна VibeWave",
        newPlaylist: "Новый плейлист",
        playlistName: "Название плейлиста",
        namePlaceholder: "Название",
        cancel: "Отмена",
        save: "Сохранить",
        ok: "Понятно",
        allMusic: "Вся музыка",
        playlists: "Плейлисты",
        createPlaylist: "Создать плейлист",
        noPlaylists: "Нет плейлистов",
        rename: "Переименовать",
        deletePlaylist: "Удалить плейлист",
        folders: "Папки",
        addMusicFolder: "Добавить папку с музыкой",
        noFolders: "Нет папок",
        refreshFolder: "Обновить содержимое",
        showInFinder: "Показать в Finder",
        removeFromLibrary: "Убрать из библиотеки",
        outsidePlaylists: "Вне плейлистов",
        playlistLabel: "Плейлист:",
        addFileButton: "+ Файл",
        addFilesHelp: "Добавить файлы MP3/FLAC",
        addFolderButton: "+ Папка",
        libraryButton: "Библиотека",
        libraryHelp: "Показать или скрыть плейлисты и папки",
        cancelImportHelp: "Остановить добавление; библиотека не изменится",
        counterHelp: "Треков и общее время",
        viewMenu: "Вид ▾",
        flatList: "Общий список",
        groupedList: "По плейлистам",
        newPlaylistMenu: "Новый плейлист…",
        viewHelp: "Вид списка и раздел",
        languageHelp: "Язык интерфейса",
        languageSystem: { "Как в системе (\($0))" },
        volume: "Громкость",
        balanceShort: "Б",
        balance: "Баланс",
        balanceHelp: "Баланс (двойной щелчок — центр)",
        position: "Позиция воспроизведения",
        timeHelp: "Щелчок: прошедшее/оставшееся время",
        idleMarquee: "VibeWave — откройте музыку и нажмите ▶",
        mono: "моно",
        stereo: "стерео",
        previousTrack: "Предыдущий трек",
        play: "Воспроизвести",
        pause: "Пауза",
        stop: "Стоп",
        nextTrack: { "Следующий: \($0)" },
        endOfQueue: "Конец очереди",
        percent: { "\($0) процентов" },
        eqHelp: "Эквалайзер",
        eqTitle: "Эквалайзер",
        eqOn: "Вкл",
        eqOnHelp: "Включить или выключить эквалайзер",
        eqPresets: "Пресеты ▾",
        eqCustom: "Свои настройки",
        eqReset: "Сброс",
        eqResetHelp: "Вернуть все полосы и предусиление к 0 дБ",
        eqPreamp: "Пред.",
        eqPresetName: { preset in
            switch preset {
            case .flat: return "Ровно"
            case .rock: return "Рок"
            case .pop: return "Поп"
            case .jazz: return "Джаз"
            case .classical: return "Классика"
            case .dance: return "Танцевальная"
            case .bassBoost: return "Больше басов"
            case .trebleBoost: return "Больше высоких"
            case .vocal: return "Вокал"
            }
        },
        eqBand: { "Полоса \($0) Гц" },
        eqDecibels: { $0.rounded() == 0 ? "0 дБ" : String(format: "%+.0f дБ", $0.rounded()) },
        trackHelp: { "\($0)\nЩелчок — играть, перетащите мышью — изменить порядок" },
        source: { "Источник: \($0)" },
        moveUp: "Выше",
        moveDown: "Ниже",
        moveToPlaylist: "Переместить в плейлист",
        addToPlaylist: "Добавить в плейлист",
        removeFromPlaylist: "Убрать из плейлиста",
        hideFromFolder: "Скрыть из папки",
        removeFromList: "Убрать из списка",
        emptyPlaylist: "Добавьте музыку в плейлист",
        emptyFolder: "В папке нет MP3 и FLAC",
        emptyLibrary: "Добавьте музыку",
        emptyHint: "Перетащите сюда файлы MP3 и FLAC или папку с музыкой",
        panelAddOutside: "Добавить музыку вне плейлистов",
        panelAddToPlaylist: "Добавить музыку в плейлист",
        progressFiles: "Чтение файлов",
        progressFolder: { "Папка «\($0)»" },
        progressFolders: { "Папки (\($0))" },
        progressSearching: { "\($0): поиск…" },
        progressCount: { "\($0): \($1) из \($2)" },
        errorImportBusy: "Дождитесь завершения текущего добавления файлов.",
        errorFolderAlreadyAdded: "Эта папка уже добавлена.",
        errorFolderUnavailableShort: { "папка «\($0)» недоступна" },
        errorFolderUnavailable: { "Папка «\($0)» недоступна. Подключите диск и повторите обновление." },
        errorPlaylistGone: "Плейлист больше не существует.",
        errorNoSupportedFiles: "Добавьте локальные файлы MP3 или FLAC.",
        errorPlaylistDeletedDuringImport: "Плейлист был удалён во время добавления файлов.",
        errorCouldNotOpen: { names, more in
            "Не удалось открыть: " + names.joined(separator: ", ") + (more > 0 ? " и ещё \(more)" : "")
        },
        errorLibraryRead: { "Не удалось прочитать библиотеку. Файл сохранён без изменений. \($0)" },
        errorLibrarySave: { "Не удалось сохранить плейлисты: \($0)" },
        errorResume: "Не удалось продолжить воспроизведение.",
        errorAudioDevice: "Аудиоустройство недоступно.",
        errorPlay: { "Не удалось воспроизвести «\($0)»: \($1)" },
        errorDragRead: "Не удалось прочитать перетаскиваемый трек.",
        updateTitle: "Доступно обновление VibeWave",
        updateMessage: { "Вышла версия \($0), у вас установлена \($1). Обновление скачается в фоне, и VibeWave перезапустится сам, когда музыка не играет." },
        updateNow: "Обновить",
        updateLater: "Позже",
        updateVerificationFailed: { "Обновление \($0) не прошло проверку и не установлено." }
    )

    public static let en = Strings(
        menuAbout: "About VibeWave",
        menuQuit: "Quit VibeWave",
        menuFile: "File",
        menuAddFiles: "Add Files…",
        menuEdit: "Edit",
        menuUndo: "Undo",
        menuCut: "Cut",
        menuCopy: "Copy",
        menuPaste: "Paste",
        menuSelectAll: "Select All",
        menuWindow: "Window",
        minimize: "Minimize",
        zoom: "Zoom",
        closeWindow: "Close Window",
        titleBar: "VibeWave title bar",
        newPlaylist: "New Playlist",
        playlistName: "Playlist Name",
        namePlaceholder: "Name",
        cancel: "Cancel",
        save: "Save",
        ok: "OK",
        allMusic: "All Music",
        playlists: "Playlists",
        createPlaylist: "Create Playlist",
        noPlaylists: "No playlists",
        rename: "Rename",
        deletePlaylist: "Delete Playlist",
        folders: "Folders",
        addMusicFolder: "Add Music Folder",
        noFolders: "No folders",
        refreshFolder: "Refresh Contents",
        showInFinder: "Show in Finder",
        removeFromLibrary: "Remove from Library",
        outsidePlaylists: "Not in Playlists",
        playlistLabel: "Playlist:",
        addFileButton: "+ File",
        addFilesHelp: "Add MP3/FLAC files",
        addFolderButton: "+ Folder",
        libraryButton: "Library",
        libraryHelp: "Show or hide playlists and folders",
        cancelImportHelp: "Stop adding; the library stays unchanged",
        counterHelp: "Tracks and total time",
        viewMenu: "View ▾",
        flatList: "Single List",
        groupedList: "By Playlist",
        newPlaylistMenu: "New Playlist…",
        viewHelp: "List view and section",
        languageHelp: "Interface language",
        languageSystem: { "System (\($0))" },
        volume: "Volume",
        balanceShort: "B",
        balance: "Balance",
        balanceHelp: "Balance (double-click to center)",
        position: "Playback position",
        timeHelp: "Click: elapsed/remaining time",
        idleMarquee: "VibeWave — open some music and press ▶",
        mono: "mono",
        stereo: "stereo",
        previousTrack: "Previous track",
        play: "Play",
        pause: "Pause",
        stop: "Stop",
        nextTrack: { "Next: \($0)" },
        endOfQueue: "End of queue",
        percent: { "\($0) percent" },
        eqHelp: "Equalizer",
        eqTitle: "Equalizer",
        eqOn: "On",
        eqOnHelp: "Turn the equalizer on or off",
        eqPresets: "Presets ▾",
        eqCustom: "Custom",
        eqReset: "Reset",
        eqResetHelp: "Set all bands and preamp back to 0 dB",
        eqPreamp: "Preamp",
        eqPresetName: { preset in
            switch preset {
            case .flat: return "Flat"
            case .rock: return "Rock"
            case .pop: return "Pop"
            case .jazz: return "Jazz"
            case .classical: return "Classical"
            case .dance: return "Dance"
            case .bassBoost: return "Bass Boost"
            case .trebleBoost: return "Treble Boost"
            case .vocal: return "Vocal"
            }
        },
        eqBand: { "Band \($0) Hz" },
        eqDecibels: { $0.rounded() == 0 ? "0 dB" : String(format: "%+.0f dB", $0.rounded()) },
        trackHelp: { "\($0)\nClick to play, drag to reorder" },
        source: { "Source: \($0)" },
        moveUp: "Move Up",
        moveDown: "Move Down",
        moveToPlaylist: "Move to Playlist",
        addToPlaylist: "Add to Playlist",
        removeFromPlaylist: "Remove from Playlist",
        hideFromFolder: "Hide from Folder",
        removeFromList: "Remove from List",
        emptyPlaylist: "Add music to this playlist",
        emptyFolder: "No MP3 or FLAC files in this folder",
        emptyLibrary: "Add some music",
        emptyHint: "Drop MP3 and FLAC files or a music folder here",
        panelAddOutside: "Add Music Outside Playlists",
        panelAddToPlaylist: "Add Music to Playlist",
        progressFiles: "Reading files",
        progressFolder: { "Folder “\($0)”" },
        progressFolders: { "Folders (\($0))" },
        progressSearching: { "\($0): searching…" },
        progressCount: { "\($0): \($1) of \($2)" },
        errorImportBusy: "Please wait until the current import finishes.",
        errorFolderAlreadyAdded: "This folder has already been added.",
        errorFolderUnavailableShort: { "folder “\($0)” is unavailable" },
        errorFolderUnavailable: { "Folder “\($0)” is unavailable. Connect the drive and refresh again." },
        errorPlaylistGone: "The playlist no longer exists.",
        errorNoSupportedFiles: "Add local MP3 or FLAC files.",
        errorPlaylistDeletedDuringImport: "The playlist was deleted while files were being added.",
        errorCouldNotOpen: { names, more in
            "Couldn’t open: " + names.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
        },
        errorLibraryRead: { "Couldn’t read the library. The file was left unchanged. \($0)" },
        errorLibrarySave: { "Couldn’t save playlists: \($0)" },
        errorResume: "Couldn’t resume playback.",
        errorAudioDevice: "The audio device is unavailable.",
        errorPlay: { "Couldn’t play “\($0)”: \($1)" },
        errorDragRead: "Couldn’t read the dragged track.",
        updateTitle: "A VibeWave update is available",
        updateMessage: { "Version \($0) is out; you have \($1). The update downloads in the background, and VibeWave restarts on its own when no music is playing." },
        updateNow: "Update",
        updateLater: "Later",
        updateVerificationFailed: { "Update \($0) failed verification and was not installed." }
    )
}
