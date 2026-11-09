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
    public let importPlaylistFile: String
    public let exportPlaylistFile: String
    public let playlistExportFormat: String
    public let playlistExportEncoding: String
    public let playlistLegacyEncoding: String
    public let playlistEncodingHelp: String
    public let playlistRelativePaths: String
    public let playlistReportMissing: String
    public let playlistReset: String
    public let invalidPlaylistFile: String
    public let invalidPlaylistEncoding: String
    public let unsupportedPlaylistStream: String
    public let playlistFileTooLarge: String
    public let unsupportedPlaylistPath: String
    public let lossyPlaylistEncoding: String
    public let missingPlaylistFile: String
    public let trackInfo: String
    public let batchTags: String
    public let trackArtwork: String
    public let chooseArtwork: String
    public let removeArtwork: String
    public let mixedTags: String
    public let tagEditHelp: String
    public let stopTagWrite: String
    public let artworkInvalid: String
    public let tagsUnsupported: String
    public let tagsDamaged: String
    public let tagsTooLarge: String
    public let tagsChanged: String
    public let tagsReadOnly: String
    public let trackRating: String
    public let noRating: String
    public let listeningHistory: String
    public let listeningEnabled: String
    public let listeningRetention: String
    public let listeningForever: String
    public let listeningEmpty: String
    public let listeningClear: String
    public let listeningClearHelp: String
    public let listeningReadOnly: String
    public let listeningThresholdHelp: String
    public let tagsUnreadableCount: @Sendable (Int) -> String
    public let tagsSavedCount: @Sendable (Int) -> String
    public let ratingStars: @Sendable (Int) -> String
    public let listeningThreshold: @Sendable (Int) -> String
    public let listeningDays: @Sendable (Int) -> String
    public let listenCount: @Sendable (Int) -> String
    public let tagFieldName: @Sendable (AudioTagField) -> String
    public let invalidTagField: @Sendable (String) -> String
    public let smartPlaylists: String
    public let createSmartPlaylist: String
    public let searchTracks: String
    public let searchFilters: String
    public let clearSearch: String
    public let noQueryResults: String
    public let queryScope: String
    public let queryCurrentScope: String
    public let queryMatch: String
    public let queryMatchAll: String
    public let queryMatchAny: String
    public let queryField: String
    public let queryOperator: String
    public let queryValue: String
    public let queryRemoveRule: String
    public let queryAddRule: String
    public let querySort: String
    public let queryManualSort: String
    public let queryDescending: String
    public let queryLimit: String
    public let queryUnits: String
    public let queryPresets: String
    public let queryEdit: String
    public let queryFieldName: @Sendable (String) -> String
    public let queryOperatorName: @Sendable (String) -> String
    public let smartPresetName: @Sendable (String) -> String
    public let menuEdit: String
    public let menuUndo: String
    public let menuCut: String
    public let menuCopy: String
    public let menuPaste: String
    public let menuSelectAll: String
    public let settingsTitle: String
    public let menuSettings: String
    public let menuPlayback: String
    public let shuffle: String
    public let repeatLabel: String
    public let repeatModeName: @Sendable (RepeatMode) -> String
    public let on: String
    public let off: String
    public let nextShuffledCycle: String
    public let resetPlaybackSettings: String
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
        importPlaylistFile: "Импортировать плейлист…",
        exportPlaylistFile: "Экспортировать плейлист…",
        playlistExportFormat: "Формат экспорта",
        playlistExportEncoding: "Кодировка экспорта M3U и PLS",
        playlistLegacyEncoding: "Кодировка для старых списков",
        playlistEncodingHelp: "M3U8 всегда использует UTF-8. Для старых M3U и PLS выбранная кодировка применяется, когда файл не читается как Unicode.",
        playlistRelativePaths: "Относительные пути",
        playlistReportMissing: "Сообщать о недоступных файлах",
        playlistReset: "Сбросить настройки плейлистов",
        invalidPlaylistFile: "Некорректный формат плейлиста.",
        invalidPlaylistEncoding: "Не удалось прочитать кодировку плейлиста.",
        unsupportedPlaylistStream: "Этот файл содержит поток HLS. Поддерживаются списки локальных треков.",
        playlistFileTooLarge: "Плейлист превышает 8 МиБ.",
        unsupportedPlaylistPath: "Поддерживаются только локальные пути без перевода строки.",
        lossyPlaylistEncoding: "Выбранная кодировка не поддерживает все символы. Выберите UTF-8 в настройках или сохраните список как M3U8.",
        missingPlaylistFile: "Файл отсутствует или недоступен.",
        trackInfo: "Сведения о треке…",
        batchTags: "Изменить теги плейлиста…",
        trackArtwork: "Обложка",
        chooseArtwork: "Выбрать обложку…",
        removeArtwork: "Удалить обложки",
        mixedTags: "Разные значения",
        tagEditHelp: "Отметьте поля, которые хотите изменить. Пустое отмеченное поле удалит тег.",
        stopTagWrite: "Остановить после файла",
        artworkInvalid: "Выберите корректный файл JPEG или PNG размером до 12 МиБ.",
        tagsUnsupported: "Структура тегов этого файла не поддерживается.",
        tagsDamaged: "Структура тегов повреждена.",
        tagsTooLarge: "Теги или обложка превышают допустимый размер.",
        tagsChanged: "Файл изменился во время записи. Откройте редактор заново.",
        tagsReadOnly: "Файл защищён от записи или имеет несколько жёстких ссылок.",
        trackRating: "Оценка",
        noRating: "Без оценки",
        listeningHistory: "История",
        listeningEnabled: "Вести историю прослушивания",
        listeningRetention: "Хранить записи истории",
        listeningForever: "Без ограничения",
        listeningEmpty: "История пуста.",
        listeningClear: "Очистить историю…",
        listeningClearHelp: "Записи, счётчики и даты последних прослушиваний будут удалены. Оценки сохранятся.",
        listeningReadOnly: "Не удалось прочитать файл истории. Для него отключена запись.",
        listeningThresholdHelp: "Короткий трек засчитывается после прослушивания половины его длительности.",
        tagsUnreadableCount: { "Файлов с недоступными тегами: \($0)" },
        tagsSavedCount: { "Сохранено файлов: \($0)" },
        ratingStars: { "Оценка: \($0) из 5" },
        listeningThreshold: { "Засчитывать после \($0) сек." },
        listeningDays: { "Дней: \($0)" },
        listenCount: { "Прослушиваний: \($0)" },
        tagFieldName: { field in
            switch field {
            case .title: return "Название"
            case .artist: return "Исполнитель"
            case .albumArtist: return "Исполнитель альбома"
            case .album: return "Альбом"
            case .genre: return "Жанр"
            case .year: return "Год"
            case .track: return "Номер трека"
            case .disc: return "Номер диска"
            case .comment: return "Комментарий"
            }
        },
        invalidTagField: { "Недопустимое значение поля «\($0)». Для года укажите четыре цифры. Номер трека или диска можно указать в виде 2/10." },
        smartPlaylists: "Умные списки",
        createSmartPlaylist: "Новый умный список…",
        searchTracks: "Поиск треков",
        searchFilters: "Фильтры",
        clearSearch: "Сбросить поиск и фильтры",
        noQueryResults: "Треки не найдены",
        queryScope: "Область поиска по умолчанию",
        queryCurrentScope: "Текущий раздел",
        queryMatch: "Условия",
        queryMatchAll: "Все",
        queryMatchAny: "Любое",
        queryField: "Поле",
        queryOperator: "Сравнение",
        queryValue: "Значение",
        queryRemoveRule: "Удалить условие",
        queryAddRule: "Добавить условие",
        querySort: "Сортировка",
        queryManualSort: "Ручной порядок",
        queryDescending: "По убыванию",
        queryLimit: "Предел треков, 0 — без предела",
        queryUnits: "Длительность в секундах. Относительные даты в днях.",
        queryPresets: "Шаблоны",
        queryEdit: "Изменить…",
        queryFieldName: { key in
            switch key {
            case "title": return "Название"
            case "artist": return "Исполнитель"
            case "album": return "Альбом"
            case "genre": return "Жанр"
            case "filename": return "Имя файла"
            case "path": return "Путь"
            case "format": return "Формат"
            case "year": return "Год"
            case "rating": return "Оценка"
            case "duration": return "Длительность"
            case "added": return "Дата добавления"
            case "lastPlayed": return "Последнее прослушивание"
            case "plays": return "Прослушивания"
            default: return key
            }
        },
        queryOperatorName: { key in
            switch key {
            case "contains": return "Содержит"
            case "equals": return "Равно"
            case "notEquals": return "Не равно"
            case "atLeast": return "Не меньше"
            case "atMost": return "Не больше"
            case "withinDays": return "За последние дни"
            case "olderThanDays": return "Старше, дней"
            case "exists": return "Указана"
            case "missing": return "Не указана"
            default: return key
            }
        },
        smartPresetName: { key in
            switch key {
            case "recentAdded": return "Недавно добавленные"
            case "recentPlayed": return "Недавно прослушанные"
            case "frequent": return "Часто слушаю"
            case "highlyRated": return "Высокая оценка"
            case "unplayed": return "Ещё не слушал"
            default: return key
            }
        },
        menuEdit: "Правка",
        menuUndo: "Отменить",
        menuCut: "Вырезать",
        menuCopy: "Копировать",
        menuPaste: "Вставить",
        menuSelectAll: "Выделить всё",
        settingsTitle: "Настройки",
        menuSettings: "Настройки…",
        menuPlayback: "Воспроизведение",
        shuffle: "Перемешивание",
        repeatLabel: "Повтор",
        repeatModeName: { mode in
            switch mode {
            case .off: return "Выключен"
            case .queue: return "Вся очередь"
            case .track: return "Текущий трек"
            }
        },
        on: "Включено",
        off: "Выключено",
        nextShuffledCycle: "Следующий случайный цикл",
        resetPlaybackSettings: "Сбросить настройки воспроизведения",
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
        importPlaylistFile: "Import Playlist…",
        exportPlaylistFile: "Export Playlist…",
        playlistExportFormat: "Export Format",
        playlistExportEncoding: "M3U and PLS Export Encoding",
        playlistLegacyEncoding: "Legacy Playlist Encoding",
        playlistEncodingHelp: "M3U8 always uses UTF-8. For older M3U and PLS files, the selected encoding is used when Unicode decoding fails.",
        playlistRelativePaths: "Relative Paths",
        playlistReportMissing: "Report Unavailable Files",
        playlistReset: "Reset Playlist Settings",
        invalidPlaylistFile: "Invalid playlist format.",
        invalidPlaylistEncoding: "Could not decode the playlist.",
        unsupportedPlaylistStream: "This file is an HLS stream. Local track lists are supported.",
        playlistFileTooLarge: "The playlist exceeds 8 MiB.",
        unsupportedPlaylistPath: "Only local paths without line breaks are supported.",
        lossyPlaylistEncoding: "The selected encoding cannot represent all characters. Choose UTF-8 in Settings or save as M3U8.",
        missingPlaylistFile: "File is missing or unavailable.",
        trackInfo: "Track Info…",
        batchTags: "Edit Playlist Tags…",
        trackArtwork: "Artwork",
        chooseArtwork: "Choose Artwork…",
        removeArtwork: "Remove Artwork",
        mixedTags: "Mixed Values",
        tagEditHelp: "Check the fields you want to change. A checked empty field removes its tag.",
        stopTagWrite: "Stop After This File",
        artworkInvalid: "Choose a valid JPEG or PNG file up to 12 MiB.",
        tagsUnsupported: "This file uses an unsupported tag layout.",
        tagsDamaged: "The tag structure is damaged.",
        tagsTooLarge: "The tags or artwork exceed the size limit.",
        tagsChanged: "The file changed during the write. Reopen the editor.",
        tagsReadOnly: "The file is read-only or has multiple hard links.",
        trackRating: "Rating",
        noRating: "Unrated",
        listeningHistory: "History",
        listeningEnabled: "Keep Listening History",
        listeningRetention: "Keep History Entries For",
        listeningForever: "No Limit",
        listeningEmpty: "No listening history yet.",
        listeningClear: "Clear History…",
        listeningClearHelp: "History entries, play counts, and last played dates will be removed. Ratings will be kept.",
        listeningReadOnly: "The history file could not be read. Writing to it is disabled.",
        listeningThresholdHelp: "A short track is counted after half of its duration has played.",
        tagsUnreadableCount: { "Files with unreadable tags: \($0)" },
        tagsSavedCount: { "Files saved: \($0)" },
        ratingStars: { "Rating: \($0) out of 5" },
        listeningThreshold: { "Count after \($0) sec" },
        listeningDays: { "\($0) days" },
        listenCount: { "Plays: \($0)" },
        tagFieldName: { field in
            switch field {
            case .title: return "Title"
            case .artist: return "Artist"
            case .albumArtist: return "Album Artist"
            case .album: return "Album"
            case .genre: return "Genre"
            case .year: return "Year"
            case .track: return "Track Number"
            case .disc: return "Disc Number"
            case .comment: return "Comment"
            }
        },
        invalidTagField: { "Invalid value for “\($0)”. Use four digits for a year. Track and disc numbers can use the form 2/10." },
        smartPlaylists: "Smart Playlists",
        createSmartPlaylist: "New Smart Playlist…",
        searchTracks: "Search Tracks",
        searchFilters: "Filters",
        clearSearch: "Clear Search and Filters",
        noQueryResults: "No Tracks Found",
        queryScope: "Default Search Scope",
        queryCurrentScope: "Current Section",
        queryMatch: "Match",
        queryMatchAll: "All",
        queryMatchAny: "Any",
        queryField: "Field",
        queryOperator: "Comparison",
        queryValue: "Value",
        queryRemoveRule: "Remove Rule",
        queryAddRule: "Add Rule",
        querySort: "Sort By",
        queryManualSort: "Original Order",
        queryDescending: "Descending",
        queryLimit: "Track Limit, 0 for No Limit",
        queryUnits: "Duration is in seconds. Relative dates are in days.",
        queryPresets: "Presets",
        queryEdit: "Edit…",
        queryFieldName: { key in
            switch key {
            case "title": return "Title"
            case "artist": return "Artist"
            case "album": return "Album"
            case "genre": return "Genre"
            case "filename": return "Filename"
            case "path": return "Path"
            case "format": return "Format"
            case "year": return "Year"
            case "rating": return "Rating"
            case "duration": return "Duration"
            case "added": return "Date Added"
            case "lastPlayed": return "Last Played"
            case "plays": return "Play Count"
            default: return key
            }
        },
        queryOperatorName: { key in
            switch key {
            case "contains": return "Contains"
            case "equals": return "Equals"
            case "notEquals": return "Does Not Equal"
            case "atLeast": return "At Least"
            case "atMost": return "At Most"
            case "withinDays": return "Within Last Days"
            case "olderThanDays": return "Older Than Days"
            case "exists": return "Has a Date"
            case "missing": return "Has No Date"
            default: return key
            }
        },
        smartPresetName: { key in
            switch key {
            case "recentAdded": return "Recently Added"
            case "recentPlayed": return "Recently Played"
            case "frequent": return "Frequently Played"
            case "highlyRated": return "Highly Rated"
            case "unplayed": return "Unplayed"
            default: return key
            }
        },
        menuEdit: "Edit",
        menuUndo: "Undo",
        menuCut: "Cut",
        menuCopy: "Copy",
        menuPaste: "Paste",
        menuSelectAll: "Select All",
        settingsTitle: "Settings",
        menuSettings: "Settings…",
        menuPlayback: "Playback",
        shuffle: "Shuffle",
        repeatLabel: "Repeat",
        repeatModeName: { mode in
            switch mode {
            case .off: return "Off"
            case .queue: return "Queue"
            case .track: return "Current track"
            }
        },
        on: "On",
        off: "Off",
        nextShuffledCycle: "Next shuffled cycle",
        resetPlaybackSettings: "Reset Playback Settings",
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
