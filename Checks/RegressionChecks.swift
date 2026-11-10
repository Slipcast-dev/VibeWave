import Foundation
import AVFoundation
import AudioToolbox
import AppKit
import Carbon.HIToolbox
import VibeWaveCore

/// Запускается без XCTest и проверяет реальную модель на временной библиотеке.
@main
@MainActor
struct RegressionChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // Проверки сверяют русские подписи; язык системы на машине проверки может быть любым.
        let languages = LanguageSettings.shared
        let savedPreference = languages.preference
        defer { languages.preference = savedPreference }
        languages.preference = .ru
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        checkShuffleOrder()
        let a = Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), duration: 84)
        let b = Track(url: URL(fileURLWithPath: "/tmp/b.flac"), duration: 100)
        let c = Track(url: URL(fileURLWithPath: "/tmp/c.mp3"), duration: 50)
        let first = Playlist(name: "Первый", tracks: [a, b, c])
        let second = Playlist(name: "Второй")
        let legacy = LibraryStore(url: support.appendingPathComponent("Tiho/library.json"))
        try legacy.save([first, second])
        let model = PlayerModel(supportDirectory: support)
        precondition(model.playlists == [first, second], "Миграция библиотеки")
        model.moveTrack(TrackDragPayload(playlistID: first.id, trackID: a.id), to: first.id, before: c.id)
        precondition(model.playlists[0].tracks == [b, a, c], "Перенос вниз")
        model.moveTrack(TrackDragPayload(playlistID: first.id, trackID: c.id), to: first.id, before: b.id)
        precondition(model.playlists[0].tracks == [c, b, a], "Перенос вверх")
        model.moveTrack(TrackDragPayload(playlistID: first.id, trackID: c.id), to: first.id, before: nil)
        precondition(model.playlists[0].tracks == [b, a, c], "Перенос в конец")
        model.moveTrack(TrackDragPayload(playlistID: first.id, trackID: a.id), to: second.id, before: nil)
        precondition(model.playlists[0].tracks == [b, c] && model.playlists[1].tracks == [a], "Между плейлистами")
        // Одинаковые файлы в другом плейлисте не должны исчезать при конфликте дублей.
        model.playlists[0].append(a)
        model.moveTrack(TrackDragPayload(playlistID: first.id, trackID: a.id), to: second.id, before: nil)
        precondition(model.playlists[0].tracks.contains(a), "Защита дубля в получателе")
        model.save()
        let restored = PlayerModel(supportDirectory: support)
        precondition(restored.playlists == model.playlists, "Сохранение порядка")
        let legacyContents = try legacy.load()
        precondition(legacyContents == [first, second], "Старая библиотека не изменена")
        let payload = TrackDragPayload(playlistID: first.id, trackID: a.id)
        let decoded = try JSONDecoder().decode(TrackDragPayload.self, from: JSONEncoder().encode(payload))
        precondition(decoded == payload, "Drag payload")
        precondition(Track.accepts(URL(fileURLWithPath: "/tmp/a.FLAC")))
        precondition(!Track.accepts(URL(string: "https://example.com/a.mp3")!))
        precondition(timeLabel(84) == "1:24")
        // Настоящие короткие аудиофайлы воспроизводят сбой обязательной security-scoped закладки.
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try checkPlaylistFileExchange(in: support, fixtures: fixtures)
        try checkTagsAndListening(in: support, fixtures: fixtures)
        try checkSearchAndSmartPlaylists(in: support, fixtures: fixtures)
        try checkNativeAudioFormats(in: support, fixtures: fixtures.deletingLastPathComponent()
            .appendingPathComponent("FormatFixtures", isDirectory: true))
        try checkAudioProcessing(in: support, fixtures: fixtures)
        try checkPlaybackSession(in: support, fixtures: fixtures)
        checkApplicationSettings(in: support)
        try checkGlobalShortcuts()
        let audioURLs = [fixtures.appendingPathComponent("silence.flac"), fixtures.appendingPathComponent("silence.mp3")]
        for url in audioURLs {
            let audio = try AVAudioPlayer(contentsOf: url)
            precondition(audio.duration > 0, "Аудиодекодер должен читать тестовый файл")
        }
        let originalPlaylists = model.playlists
        model.selectedID = second.id
        // Передача без явного назначения никогда не выбирает текущий плейлист автоматически.
        model.receiveFiles(audioURLs)
        waitFor { !model.importing }
        precondition(model.error == nil && model.openTracks.count == 2, "Импорт вне плейлистов")
        precondition(model.playlists == originalPlaylists, "Обычное открытие не изменяет плейлисты")
        let reloaded = PlayerModel(supportDirectory: support)
        precondition(reloaded.playlists == originalPlaylists && reloaded.openTracks.isEmpty, "Временная очередь не сохраняется как плейлист")

        // В новой библиотеке нет ни одного автоматически созданного плейлиста.
        let dropModel = PlayerModel(supportDirectory: support.appendingPathComponent("DropCheck"))
        precondition(dropModel.playlists.isEmpty && dropModel.selectedID == nil)
        let providers = audioURLs.compactMap { NSItemProvider(contentsOf: $0) }
        precondition(providers.count == 2 && providers.allSatisfy { !DropReceiver.isInternal($0) })
        precondition(DropReceiver.receive(providers, model: dropModel, playlistID: nil))
        waitFor { dropModel.openTracks.count == 2 || dropModel.error != nil }
        precondition(dropModel.error == nil && dropModel.openTracks.count == 2, dropModel.error ?? "Provider import failed")
        precondition(dropModel.playlists.isEmpty, "Перетаскивание не создаёт плейлист")

        // Плейлист создаётся только явной командой пользователя, импорт в него — явным ID.
        dropModel.createPlaylist("Мой плейлист")
        let manualID = dropModel.selectedID!
        precondition(DropReceiver.receive(providers, model: dropModel, playlistID: manualID))
        waitFor { dropModel.playlists.first?.tracks.count == 2 || dropModel.error != nil }
        precondition(dropModel.error == nil && dropModel.playlists.count == 1 && dropModel.playlists[0].tracks.count == 2)
        precondition(dropModel.openTracks.count == 2, "Добавление в плейлист не меняет очередь")

        // Открытие через Finder переводит в очередь, даже при выбранном плейлисте.
        let manualBeforeOpen = dropModel.playlists
        dropModel.openFiles(audioURLs)
        waitFor { !dropModel.importing }
        precondition(dropModel.selectedID == nil && dropModel.playlists == manualBeforeOpen)
        dropModel.stop()

        // Добавление из очереди в вручную созданный плейлист не удаляет исходную очередь.
        let queued = dropModel.openTracks[0]
        dropModel.createPlaylist("Получатель")
        let targetID = dropModel.selectedID!
        let queueProvider = trackProvider(queued, playlistID: nil)
        precondition(DropReceiver.isInternal(queueProvider))
        precondition(DropReceiver.receive([queueProvider], model: dropModel, playlistID: targetID))
        waitFor { dropModel.selected?.tracks.count == 1 || dropModel.error != nil }
        precondition(dropModel.selected?.tracks.first?.id == queued.id && dropModel.openTracks.count == 2)

        // nil не должен подменяться выбранным плейлистом и при внутреннем переносе.
        let lastQueued = dropModel.openTracks[1]
        let reorderProvider = trackProvider(lastQueued, playlistID: nil)
        precondition(DropReceiver.receive([reorderProvider], model: dropModel, playlistID: nil, before: queued.id))
        waitFor { dropModel.openTracks.first?.id == lastQueued.id }
        precondition(dropModel.selected?.tracks.count == 1, "Перестановка очереди не затрагивает выбранный плейлист")

        // Обычные переносы между плейлистами по-прежнему работают.
        let source = dropModel.playlists.first(where: { $0.id == manualID })!
        let moved = source.tracks.first(where: { $0.url != queued.url })!
        let internalProvider = trackProvider(moved, playlistID: manualID)
        precondition(DropReceiver.receive([internalProvider], model: dropModel, playlistID: targetID))
        waitFor { dropModel.selected?.tracks.count == 2 || dropModel.error != nil }
        precondition(dropModel.error == nil && dropModel.playlists.first(where: { $0.id == manualID })?.tracks.count == 1)
        let finalModel = PlayerModel(supportDirectory: support.appendingPathComponent("DropCheck"))
        precondition(finalModel.playlists == dropModel.playlists && finalModel.openTracks.isEmpty)
        for id in dropModel.playlists.map(\.id) { dropModel.deletePlaylist(id) }
        precondition(dropModel.playlists.isEmpty && dropModel.openTracks.count == 2)
        dropModel.receiveFiles(audioURLs)
        waitFor { !dropModel.importing }
        precondition(dropModel.playlists.isEmpty, "Удалённые плейлисты не воссоздаются при импорте")
        print("PASS: no automatic playlists, independent open queue, manual playlist import, Finder open routing")
        print("PASS: external providers, internal queue reordering, queue-to-playlist copy, playlist moves, persistence")
        // Постоянный список вне плейлистов действует на свой источник, а не на выбранный плейлист.
        dropModel.createPlaylist("Не трогать")
        let selectedID = dropModel.selectedID!
        let firstOutside = dropModel.openTracks[0]
        dropModel.moveTrackBy(firstOutside.id, in: nil, offset: 1)
        precondition(dropModel.openTracks.last?.id == firstOutside.id)
        precondition(dropModel.selectedID == selectedID && dropModel.selected?.tracks.isEmpty == true)
        dropModel.moveTrackBy(firstOutside.id, in: nil, offset: -1)
        precondition(dropModel.openTracks.first?.id == firstOutside.id)

        // Следующий/предыдущий идут по списку; ручной перенос сразу меняет следующий трек.
        let orderModel = PlayerModel(supportDirectory: support.appendingPathComponent("OrderCheck"))
        orderModel.openTracks = dropModel.openTracks
        let starting = orderModel.openTracks[0]
        orderModel.play(starting, in: orderModel.openTracks)
        if orderModel.playing { orderModel.toggle() }
        let expectedNext = orderModel.nextTrack!
        precondition(expectedNext.id == orderModel.openTracks[1].id, "Очередь идёт по списку")
        orderModel.next()
        if orderModel.playing { orderModel.toggle() }
        precondition(orderModel.current?.id == expectedNext.id)
        orderModel.previous()
        if orderModel.playing { orderModel.toggle() }
        precondition(orderModel.current?.id == starting.id && orderModel.nextTrack?.id == expectedNext.id)
        orderModel.moveTrackBy(starting.id, in: nil, offset: 1)
        precondition(orderModel.openTracks.last?.id == starting.id && orderModel.nextTrack == nil)
        orderModel.moveTrackBy(starting.id, in: nil, offset: -1)
        precondition(orderModel.nextTrack?.id == expectedNext.id, "Следующий трек соответствует ручному порядку")
        orderModel.stop()
        let originalPlaylist = dropModel.playlists
        dropModel.removeTrack(firstOutside.id, from: nil)
        precondition(!dropModel.openTracks.contains(where: { $0.id == firstOutside.id }))
        precondition(dropModel.playlists == originalPlaylist && dropModel.selectedID == selectedID)
        print("PASS: explicit outside-queue actions, manual order, in-order navigation")

        // Воспроизведение через AVAudioEngine с эквалайзером: длительность, перемотка,
        // смена настроек без остановки, автопереход и остановка после последнего трека.
        let savedEqualizer = UserDefaults.standard.data(forKey: PlayerModel.equalizerKey)
        defer {
            if let data = savedEqualizer { UserDefaults.standard.set(data, forKey: PlayerModel.equalizerKey) }
            else { UserDefaults.standard.removeObject(forKey: PlayerModel.equalizerKey) }
        }
        let audioModel = PlayerModel(supportDirectory: support.appendingPathComponent("AudioCheck"))
        audioModel.receiveFiles(audioURLs)
        waitFor { !audioModel.importing }
        let clips = audioModel.openTracks
        precondition(clips.count == 2 && abs(clips[0].duration - 0.1) < 0.02 && abs(clips[1].duration - 0.26) < 0.03,
                     "Длительность FLAC и MP3 по AVAudioFile")
        audioModel.equalizer = EqualizerSettings(preset: .bassBoost)
        audioModel.play(clips[1], in: clips)
        precondition(audioModel.playing && audioModel.current?.id == clips[1].id && audioModel.duration > 0.2, audioModel.error ?? "Воспроизведение")
        audioModel.equalizer.gains[0] = -6
        audioModel.equalizer.enabled = false
        precondition(audioModel.playing && audioModel.current?.id == clips[1].id, "Смена эквалайзера не прерывает трек")
        audioModel.seek(0.05)
        precondition(abs(audioModel.position - 0.05) < 0.01, "Перемотка")
        waitFor { audioModel.current == nil }
        precondition(!audioModel.playing && audioModel.error == nil, "После последнего трека воспроизведение останавливается")
        audioModel.play(clips[0], in: clips)
        waitFor { audioModel.current?.id == clips[1].id || audioModel.error != nil }
        precondition(audioModel.error == nil, "Автопереход к следующему треку")
        audioModel.stop()
        let reopenedAudio = PlayerModel(supportDirectory: support.appendingPathComponent("AudioCheck"))
        precondition(reopenedAudio.equalizer == audioModel.equalizer && reopenedAudio.equalizer.gains[0] == -6, "Эквалайзер сохраняется")
        print("PASS: AVAudioEngine playback, equalizer changes while playing, seek, auto-advance, stop at end, equalizer persistence")
        checkPlaybackModes(in: support, clips: clips)
        // Папки, общий список «Вся музыка», ручной порядок и группировка.
        let libraryModel = PlayerModel(supportDirectory: support.appendingPathComponent("LibraryCheck"))
        libraryModel.groupByPlaylists = false
        libraryModel.receiveFiles([fixtures])
        waitFor { !libraryModel.importing }
        precondition(libraryModel.error == nil && libraryModel.folders.count == 1, libraryModel.error ?? "Папка не добавлена")
        let folder = libraryModel.folders[0]
        precondition(folder.tracks.count == 2 && libraryModel.selectedID == folder.id, "Сканирование папки")
        libraryModel.createPlaylist("Сборник")
        let mixID = libraryModel.selectedID!
        libraryModel.moveTrack(TrackDragPayload(playlistID: folder.id, trackID: folder.tracks[0].id), to: mixID, before: nil)
        precondition(libraryModel.folders[0].tracks.count == 2 && libraryModel.selected?.tracks.count == 1, "Из папки трек копируется")
        precondition(libraryModel.libraryEntries.count == 2, "Общий список без дублей")
        libraryModel.moveTrack(TrackDragPayload(playlistID: mixID, trackID: folder.tracks[0].id), to: folder.id, before: nil)
        precondition(libraryModel.selected?.tracks.count == 1, "В папку извне ничего не переносится")
        let before = libraryModel.libraryEntries.map(\.id)
        libraryModel.moveInLibrary(before[1], before: before[0])
        precondition(libraryModel.libraryEntries.map(\.id) == [before[1], before[0]], "Ручной порядок общего списка")
        precondition(libraryModel.playlists[0].tracks.count == 1 && libraryModel.folders[0].tracks.count == 2, "Порядок не трогает источники")
        libraryModel.selectedID = nil
        precondition(libraryModel.isLibrarySelected && libraryModel.visibleTracks.map(\.id) == [before[1], before[0]])
        libraryModel.groupByPlaylists = true
        precondition(libraryModel.librarySections.map(\.kind) == [.playlist, .folder, .loose])
        precondition(libraryModel.visibleTracks.map(\.id) == [before[0], before[1]], "Очередь по разделам без повторов")
        libraryModel.groupByPlaylists = false
        // Недоступная папка при обновлении не теряет треки.
        let missingRoot = support.appendingPathComponent("Missing", isDirectory: true)
        try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audioURLs[1], to: missingRoot.appendingPathComponent("one.mp3"))
        libraryModel.addFolders([missingRoot])
        waitFor { !libraryModel.importing }
        let missingID = libraryModel.folders.first { $0.url.standardizedFileURL == missingRoot.standardizedFileURL }!.id
        try FileManager.default.removeItem(at: missingRoot)
        libraryModel.rescanFolder(missingID)
        waitFor { !libraryModel.importing }
        precondition(libraryModel.folders.first { $0.id == missingID }?.tracks.count == 1 && libraryModel.error != nil, "Недоступная папка не очищается")
        libraryModel.error = nil
        libraryModel.removeFolder(missingID)
        libraryModel.selectedID = nil
        let reopened = PlayerModel(supportDirectory: support.appendingPathComponent("LibraryCheck"))
        precondition(reopened.folders == libraryModel.folders && reopened.playlists == libraryModel.playlists, "Папки сохраняются")
        precondition(reopened.libraryEntries.map(\.id) == [before[1], before[0]], "Порядок общего списка сохраняется")
        libraryModel.receiveFiles([fixtures])
        waitFor { !libraryModel.importing }
        precondition(libraryModel.folders.count == 1, "Повторная папка не добавляется")
        libraryModel.error = nil
        libraryModel.removeFolder(folder.id)
        precondition(libraryModel.folders.isEmpty && libraryModel.libraryEntries.count == 1)

        // В папку попадают только обычные файлы: каталог «Album.mp3» и скрытые файлы пропускаются.
        let mixed = support.appendingPathComponent("Mixed", isDirectory: true)
        let album = mixed.appendingPathComponent("Album.mp3", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audioURLs[0], to: album.appendingPathComponent("inner.flac"))
        try FileManager.default.copyItem(at: audioURLs[1], to: mixed.appendingPathComponent("Track 2.mp3"))
        try FileManager.default.copyItem(at: audioURLs[1], to: mixed.appendingPathComponent(".hidden.mp3"))
        libraryModel.addFolders([mixed])
        precondition(libraryModel.importing && libraryModel.importProgress != nil, "Прогресс виден во время сканирования")
        waitFor { !libraryModel.importing }
        precondition(libraryModel.importProgress == nil, "Прогресс скрывается после завершения")
        precondition(libraryModel.error == nil, libraryModel.error ?? "Каталог с расширением .mp3 не должен давать ошибку")
        let mixedFolder = libraryModel.folders.first { $0.url.standardizedFileURL == mixed.standardizedFileURL }!
        precondition(Set(mixedFolder.tracks.map(\.url.lastPathComponent)) == ["inner.flac", "Track 2.mp3"], "Только обычные видимые файлы")

        // Обновление сохраняет ID известных треков и дочитывает только новые файлы.
        let knownIDs = mixedFolder.tracks.map(\.id)
        try FileManager.default.copyItem(at: audioURLs[1], to: mixed.appendingPathComponent("Track 10.mp3"))
        libraryModel.rescanFolder(mixedFolder.id)
        waitFor { !libraryModel.importing }
        let rescanned = libraryModel.folders.first { $0.id == mixedFolder.id }!
        precondition(libraryModel.error == nil && rescanned.tracks.count == 3, libraryModel.error ?? "Новый файл не добавлен")
        precondition(Array(rescanned.tracks.map(\.id).prefix(2)) == knownIDs && rescanned.tracks.last?.url.lastPathComponent == "Track 10.mp3",
                     "Известные треки сохраняют ID и порядок")

        // Отмена сразу разблокирует интерфейс и не меняет библиотеку.
        let foldersBeforeCancel = libraryModel.folders
        libraryModel.addFolders([fixtures])
        precondition(libraryModel.importing)
        libraryModel.cancelImport()
        precondition(!libraryModel.importing && libraryModel.importProgress == nil, "Отмена снимает блокировку")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(libraryModel.folders == foldersBeforeCancel && libraryModel.error == nil, "Отменённая задача не меняет библиотеку")
        let queueBeforeCancel = libraryModel.openTracks
        libraryModel.importURLs(audioURLs, into: nil)
        libraryModel.cancelImport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(libraryModel.openTracks == queueBeforeCancel, "Отменённый импорт файлов не добавляет треки")
        libraryModel.removeFolder(mixedFolder.id)
        print("PASS: regular-file filter, incremental rescan, import progress and cancellation")
        print("PASS: folders, unified library list, manual library order, grouping, persistence")
        if CommandLine.arguments.count > 2 {
            let bundle = Bundle(path: CommandLine.arguments[2])!
            let iconURL = bundle.url(forResource: "VibeWaveIcon", withExtension: "icns")!
            let icon = NSImage(contentsOf: iconURL)
            precondition(icon?.isValid == true, "Иконка должна читаться AppKit")
            let audio = (bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])?
                .first { $0["CFBundleTypeName"] as? String == "Local Audio" }
            precondition(Set(audio?["CFBundleTypeExtensions"] as? [String] ?? []) == Set(AudioFormat.allCases.flatMap(\.fileExtensions)),
                         "Расширения Finder должны совпадать с реестром форматов")
            precondition(Set(audio?["LSItemContentTypes"] as? [String] ?? []) ==
                Set(AudioFormat.allCases.flatMap(\.contentTypes).map(\.identifier)),
                         "Типы Finder должны совпадать с диалогом открытия")
        }
        // Окно рисует SwiftUI через Metal; на виртуальных машинах без видеокарты (GitHub Actions)
        // это падает в системной библиотеке, поэтому там проверки окна отключаются явно.
        if ProcessInfo.processInfo.environment["VIBEWAVE_SKIP_WINDOW_CHECKS"] == "1" {
            print("SKIP: window checks (VIBEWAVE_SKIP_WINDOW_CHECKS=1, no GPU)")
        } else {
            // Проверяем новое borderless-окно и реальные контролы заголовка вне пользовательского окна.
            let controller = RetroWindowController(model: dropModel)
            let window = controller.window!
            precondition(!window.styleMask.contains(.titled), "Полоса macOS должна отсутствовать")
            precondition(window.canBecomeKey && window.canBecomeMain, "Клавиатура должна работать")
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let caption = findCaption(in: window.contentView!)!
            let buttons = caption.subviews.compactMap { $0 as? RetroCaptionButton }
            precondition(buttons.count == 3 && buttons.allSatisfy { $0.target != nil && $0.action != nil })
            precondition(Set(buttons.compactMap(\.toolTip)) == Set(["Свернуть", "Развернуть или восстановить", "Закрыть окно"]))
            if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                let original = window.frame
                window.zoom(nil)
                waitFor { window.frame == visible }
                window.zoom(nil)
                waitFor { window.frame == original }
            }
            window.close()
            print("PASS: borderless key window, three connected caption buttons, maximize/restore")
        }
        // Переключение языка меняет строки модели, разделы библиотеки и ход импорта сразу.
        let languageModel = PlayerModel(supportDirectory: support.appendingPathComponent("LanguageCheck"))
        precondition(languageModel.selectedTitle == "Вся музыка" && languageModel.librarySections.last?.title == "Вне плейлистов")
        languages.preference = .en
        precondition(languages.language == .en && languageModel.selectedTitle == "All Music", "Английский интерфейс")
        precondition(languageModel.librarySections.last?.title == "Not in Playlists")
        languageModel.addFolders([fixtures])
        precondition(languageModel.importProgress?.label(languageModel.strings).hasPrefix("Folder “Fixtures”") == true, "Ход импорта на английском")
        languages.preference = .ru
        precondition(languageModel.importProgress?.label(languageModel.strings).hasPrefix("Папка «Fixtures»") == true, "Ход импорта переключается сразу")
        waitFor { !languageModel.importing }
        languageModel.receiveFiles([fixtures])
        precondition(languageModel.error == "Эта папка уже добавлена.")
        languages.preference = .en
        languageModel.error = nil
        languageModel.receiveFiles([fixtures])
        precondition(languageModel.error == "This folder has already been added.", "Сообщения модели на английском")
        let caption = RetroCaptionView(theme: .retro, strings: languages.strings)
        precondition(Set(caption.subviews.compactMap { ($0 as? NSButton)?.toolTip }) == ["Minimize", "Zoom", "Close Window"])
        languages.preference = .ru
        caption.strings = languages.strings
        precondition(Set(caption.subviews.compactMap { ($0 as? NSButton)?.toolTip }) == ["Свернуть", "Развернуть или восстановить", "Закрыть окно"],
                     "Подсказки кнопок окна переключаются")
        print("PASS: Russian/English switching for model messages, library sections, import progress, caption buttons")
        try checkUpdateInstallation(in: support.appendingPathComponent("UpdateCheck", isDirectory: true))
        print("PASS: real MP3/FLAC import and valid app icon")
        print("PASS: migration, reorder up/down/end, cross-playlist move, duplicates, persistence, payload, formats")
    }
    private static func checkGlobalShortcuts() throws {
        let suite = "VibeWave.ShortcutChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = GlobalShortcuts(defaults: defaults)
        precondition(!shortcuts.enabled && shortcuts.bindings.count == ShortcutAction.allCases.count)
        shortcuts.clear(.stop)
        precondition(GlobalShortcuts(defaults: defaults).bindings[.stop] == nil, "Очистка сохраняется")
        shortcuts.reset()
        precondition(GlobalShortcuts(defaults: defaults).bindings[.stop] != nil, "Сброс сохраняется")

        // Регистрация требует сессии WindowServer. Проверки хранения выше проходят и без неё.
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("SKIP: native global shortcut checks (no WindowServer session)")
            return
        }
        for action in ShortcutAction.allCases { shortcuts.clear(action) }
        let modifiers = controlKey | optionKey | shiftKey | cmdKey
        let play = ShortcutBinding(keyCode: kVK_ANSI_Keypad5, modifiers: modifiers, keyLabel: "5")
        let occupied = ShortcutBinding(keyCode: kVK_ANSI_Keypad6, modifiers: modifiers, keyLabel: "6")
        func register(_ binding: ShortcutBinding) -> (OSStatus, EventHotKeyRef?) {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                             EventHotKeyID(signature: 0x56775473, id: binding.keyCode),
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            return (status, reference)
        }
        func assertAvailable(_ binding: ShortcutBinding) {
            let (status, reference) = register(binding)
            precondition(status == noErr && reference != nil, "Проверочная клавиша недоступна: \(status)")
            UnregisterEventHotKey(reference)
        }
        func assertOccupied(_ binding: ShortcutBinding) {
            let (status, reference) = register(binding)
            if let reference = reference { UnregisterEventHotKey(reference) }
            precondition(status != noErr, "Глобальное сочетание должно оставаться зарегистрированным")
        }

        shortcuts.start { _ in }
        defer { shortcuts.stop() }
        try shortcuts.assign(play, to: .playPause)
        assertAvailable(play)
        do {
            try shortcuts.assign(play, to: .next)
            preconditionFailure("Редактор должен отклонить внутренний дубликат")
        } catch ShortcutIssue.duplicate(.playPause) {}
        do {
            try shortcuts.assign(ShortcutBinding(keyCode: kVK_ANSI_Q, modifiers: cmdKey, keyLabel: "Q"), to: .next)
            preconditionFailure("Редактор должен сохранить сочетание закрытия приложения")
        } catch ShortcutIssue.reserved {}

        shortcuts.setEnabled(true)
        assertOccupied(play)
        let (status, external) = register(occupied)
        precondition(status == noErr && external != nil)
        defer { UnregisterEventHotKey(external) }
        do {
            try shortcuts.assign(occupied, to: .playPause)
            preconditionFailure("Редактор должен отклонить сочетание, занятое в macOS")
        } catch ShortcutIssue.unavailable {}
        precondition(shortcuts.bindings[.playPause] == play && shortcuts.conflicts.isEmpty)
        assertOccupied(play)
        shortcuts.beginCapture()
        assertAvailable(play)
        shortcuts.endCapture()
        assertOccupied(play)
        let reloaded = GlobalShortcuts(defaults: defaults)
        precondition(reloaded.enabled && reloaded.bindings == [.playPause: play])
        shortcuts.setEnabled(false)
        assertAvailable(play)
        shortcuts.clear(.playPause)
        let cleared = GlobalShortcuts(defaults: defaults)
        precondition(!cleared.enabled && cleared.bindings.isEmpty)
        print("PASS: native global shortcut registration, conflicts, capture suspension, disabling and persistence")
    }

    /// Проверяем настоящий кодек, а не только расширение. Фикстуры содержат синтетический сигнал.
    private static func checkAudioProcessing(in support: URL, fixtures: URL) throws {
        let directory = support.appendingPathComponent("AudioProcessing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func clip(_ name: String, value: Float, rate: Double = 8_000) throws -> Track {
            let url = directory.appendingPathComponent(name + ".wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
            pcm.frameLength = pcm.frameCapacity
            for channel in 0..<2 {
                pcm.floatChannelData![channel].initialize(repeating: value, count: Int(pcm.frameLength))
            }
            try writer.write(from: pcm)
            return Track(url: url, duration: 8_000 / rate)
        }
        let first = try clip("first", value: 0.25)
        let second = try clip("second", value: -0.25)
        let different = try clip("different", value: 0.125, rate: 16_000)
        func item(_ track: Track) -> AudioStreamItem { AudioStreamItem(track: track, cachedGain: nil) }

        func rendered(_ options: AudioPlaybackOptions, next: Track, consumed: Int) throws -> [Float] {
            let plan = AudioStreamPlan(current: item(first), upcoming: [item(next)], options: options,
                                       equalizer: EqualizerSettings())
            let stream = AudioTransitionStream(plan: plan, url: first.url, start: 0)
            let batch = try stream.produce(maximum: 32)
            precondition(batch.done)
            let boundaries = batch.chunks.compactMap(\.boundary)
            if consumed < 0 { precondition(boundaries.isEmpty) }
            else { precondition(boundaries.count == 1 && boundaries[0].consumed == consumed) }

            let format = batch.chunks.first!.buffer.format
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
            try engine.start()
            defer { engine.stop() }
            for chunk in batch.chunks { node.scheduleBuffer(chunk.buffer, at: nil) }
            node.play()
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
            let total = batch.chunks.reduce(0) { $0 + Int($1.buffer.frameLength) }
            var samples: [Float] = []
            while samples.count < total {
                let status = try engine.renderOffline(AVAudioFrameCount(min(1_024, total - samples.count)), to: output)
                precondition(status == .success && output.frameLength > 0, "Офлайн-рендер")
                samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            return samples
        }

        var options = AudioPlaybackOptions()
        options.gapless = true
        let gapless = try rendered(options, next: second, consumed: 0)
        precondition(gapless.count == 16_000 && abs(gapless[7_999] - 0.25) < 0.001 && abs(gapless[8_000] + 0.25) < 0.001)
        let fallback = try rendered(options, next: different, consumed: -1)
        precondition(fallback.count == 8_000)
        options.crossfade = 0.5
        let repeated = try rendered(options, next: first, consumed: 0)
        precondition(repeated.count == 16_000 && abs(repeated[8_000] - 0.25) < 0.001)
        let faded = try rendered(options, next: second, consumed: 4_000)
        precondition(faded.count == 12_000 && abs(faded[3_999] - 0.25) < 0.001 &&
                     abs(faded[5_999]) < 0.001 && abs(faded[8_000] + 0.25) < 0.001)

        let album = try ["album-a", "album-b"].map { name in
            let url = directory.appendingPathComponent(name + ".flac")
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("silence.flac"), to: url)
            var edit = AudioTagEdit()
            edit.fields = [.album: "Test Album", .albumArtist: "Test Artist"]
            _ = try AudioMetadataFile.write(edit, to: url)
            return Track(url: url, duration: 0)
        }
        var albumOptions = options
        albumOptions.gapless = false
        let albumPlan = AudioStreamPlan(current: item(album[0]), upcoming: [item(album[1])],
                                        options: albumOptions, equalizer: EqualizerSettings())
        let albumBatch = try AudioTransitionStream(plan: albumPlan, url: album[0].url, start: 0).produce(maximum: 32)
        precondition(albumBatch.done && albumBatch.chunks.compactMap(\.boundary).first?.consumed == 0)

        let defaultsKey = "VibeWave.AudioChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsKey)!
        defer { defaults.removePersistentDomain(forName: defaultsKey) }
        let model = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        model.audioOptions = options
        model.openTracks = [first, second, different]
        model.play(first, in: model.openTracks)
        precondition(model.playing)
        model.seek(0.25)
        model.toggle()
        precondition(!model.playing && model.current?.id == first.id)
        model.toggle()
        waitFor { model.current?.id == second.id || model.error != nil }
        precondition(model.error == nil && model.position >= 0.49, model.error ?? "Позиция после сведения")
        waitFor { model.current?.id == different.id || model.error != nil }
        precondition(model.error == nil, model.error ?? "Штатный переход к другому формату")
        model.stop()
        let restored = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        precondition(restored.audioOptions == options)

        let eq = EqualizerSettings(enabled: true, preamp: -5, gains: [-6, 2, 3])
        let preset = try model.userEqualizerPresets.add(name: "Мой EQ", settings: eq)
        let transfer = try EqualizerPresetFile.decode(EqualizerPresetFile.encode(preset))
        let imported = try model.userEqualizerPresets.addImported(transfer)
        precondition(imported.id != preset.id && imported.gains == eq.gains && imported.preamp == eq.preamp)
        try model.userEqualizerPresets.rename(preset.id, to: "Переименован")
        try model.userEqualizerPresets.remove(imported.id)
        let savedPresets = EqualizerPresetLibrary(defaults: defaults).presets
        precondition(savedPresets.count == 1 && savedPresets[0].name == "Переименован" && savedPresets[0].preamp == eq.preamp)

        options.replayGain = .album
        let values = ReplayGainValues(trackGain: 10, albumGain: -6, trackPeak: 0.5, albumPeak: 0.8)
        precondition(options.gain(values, equalizer: EqualizerSettings()) == -6)
        options.replayGain = .track
        precondition(abs(options.gain(values, equalizer: EqualizerSettings()) - 6.0206) < 0.001)
        model.analyzeGain([first])
        waitFor { model.gainJob == nil }
        precondition(model.gainStore.values(for: first)?.trackPeak == 0.25, model.gainReport ?? "Кэш ReplayGain")
        let reopened = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        precondition(reopened.gainStore.values(for: first)?.trackPeak == 0.25)
        model.analyzeGain([second])
        model.gainJob?.cancel()
        waitFor { model.gainJob == nil }
        precondition(model.gainStore.values(for: second) == nil && model.gainStore.values(for: first)?.trackPeak == 0.25)
        print("PASS: rendered gapless and crossfade, album exception, repeat, seek, pause, format fallback, ReplayGain cache and cancellation, EQ preset transfer")
    }

    static func checkNativeAudioFormats(in support: URL, fixtures: URL) throws {
        let manager = FileManager.default
        let root = support.appendingPathComponent("NativeFormats", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let cases: [(String, AudioFormat, AudioFormatID, UInt32)] = [
            ("tone.wav", .wave, kAudioFormatLinearPCM, 2), ("rf64.wav", .wave, kAudioFormatLinearPCM, 2),
            ("surround.wav", .wave, kAudioFormatLinearPCM, 6), ("tone.w64", .wave64, kAudioFormatLinearPCM, 2),
            ("tone.aiff", .aiff, kAudioFormatLinearPCM, 2), ("tone.aifc", .aiff, kAudioFormatLinearPCM, 2),
            ("tone.aac", .adts, kAudioFormatMPEG4AAC, 2), ("aac.m4a", .mpeg4, kAudioFormatMPEG4AAC, 2),
            ("alac.m4a", .mpeg4, kAudioFormatAppleLossless, 2), ("tone.m4b", .mpeg4, kAudioFormatMPEG4AAC, 2),
            ("tone.m4r", .mpeg4, kAudioFormatMPEG4AAC, 2), ("pcm.caf", .caf, kAudioFormatLinearPCM, 2),
            ("opus.caf", .caf, kAudioFormatOpus, 2), ("tone.au", .au, kAudioFormatULaw, 1)
        ]
        let urls = cases.map { fixtures.appendingPathComponent($0.0) }
        for ((name, format, codec, channels), url) in zip(cases, urls) {
            let file = try AudioDecoding.open(url)
            precondition(AudioFormat(url: url) == format && file.fileFormat.streamDescription.pointee.mFormatID == codec &&
                         file.fileFormat.channelCount == channels && file.framePosition == 0, name)
        }

        let suite = "VibeWave.NativeFormatCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        model.listeningOptions.enabled = false
        model.receiveFiles(urls)
        waitFor { !model.importing }
        precondition(model.error == nil && model.openTracks.map(\.url.lastPathComponent) == cases.map { $0.0 },
                     model.error ?? "Импорт всех нативных форматов")
        let tracks = model.openTracks
        precondition(tracks.allSatisfy { $0.duration > 0.3 && $0.duration < 0.6 })
        model.play(tracks[0], in: tracks)
        for (index, track) in tracks.enumerated() {
            waitFor { model.current?.id == track.id || model.error != nil }
            precondition(model.playing && model.error == nil && model.currentChannels == Int(cases[index].3),
                         model.error ?? track.title)
            model.seek(0.1)
            precondition(abs(model.position - 0.1) < 0.01)
        }
        waitFor { model.current == nil || model.error != nil }
        precondition(model.error == nil && !model.playing, model.error ?? "Автопереход и остановка")

        let aliases = [("tone.wav", "copy.WAVE"), ("tone.aiff", "copy.aif"), ("tone.aac", "copy.adts"), ("tone.au", "copy.snd")]
        let aliasFolder = root.appendingPathComponent("Aliases", isDirectory: true)
        try manager.createDirectory(at: aliasFolder, withIntermediateDirectories: true)
        for (original, alias) in aliases {
            let url = aliasFolder.appendingPathComponent(alias)
            try manager.copyItem(at: fixtures.appendingPathComponent(original), to: url)
            _ = try AudioDecoding.open(url)
        }
        model.addFolders([aliasFolder])
        waitFor { !model.importing }
        precondition(model.error == nil && model.folders.last?.tracks.count == aliases.count)
        let dragURL = aliasFolder.appendingPathComponent("copy.snd")
        let provider = NSItemProvider(contentsOf: dragURL)!
        precondition(DropReceiver.receive([provider], model: model, playlistID: nil))
        waitFor { model.openTracks.contains { $0.url.lastPathComponent == "copy.snd" } }
        model.openFiles([aliasFolder.appendingPathComponent("copy.aif")])
        waitFor { !model.importing }
        precondition(model.playing && model.current?.url.lastPathComponent == "copy.aif")
        model.stop()

        let playlist = root.appendingPathComponent("Formats.m3u8")
        try "Aliases/copy.WAVE\nAliases/copy.adts\n".write(to: playlist, atomically: true, encoding: .utf8)
        model.receiveFiles([playlist])
        waitFor { !model.importing }
        precondition(model.error == nil && model.selected?.tracks.map(\.url.lastPathComponent) == ["copy.WAVE", "copy.adts"])

        let m4a = fixtures.appendingPathComponent("aac.m4a")
        let tags = try AudioMetadataFile.read(m4a)
        precondition(tags.fields[.title] == "Тест AAC" && tags.fields[.artist] == "VibeWave" && tags.artwork?.mime == "image/png")
        precondition(tracks.first { $0.url.lastPathComponent == "aac.m4a" }?.title == "Тест AAC")
        var edit = AudioTagEdit()
        edit.fields = [.title: "No overwrite"]
        let original = try Data(contentsOf: m4a)
        do {
            _ = try AudioMetadataFile.write(edit, to: m4a)
            preconditionFailure("M4A metadata is read-only")
        } catch AudioMetadataFile.Failure.unsupportedLayout {}
        let stillOriginal = try Data(contentsOf: m4a)
        precondition(original == stillOriginal)

        let damaged = root.appendingPathComponent("Damaged.wav")
        try Data("not audio".utf8).write(to: damaged)
        let drm = root.appendingPathComponent("Protected.m4p")
        try manager.copyItem(at: m4a, to: drm)
        let unknownCodec = root.appendingPathComponent("UnknownCodec.wav")
        var altered = try Data(contentsOf: fixtures.appendingPathComponent("tone.wav"))
        altered[20] = 0xFF
        altered[21] = 0xFF
        try altered.write(to: unknownCodec)
        model.receiveFiles([damaged, drm, unknownCodec])
        waitFor { !model.importing }
        precondition(model.openTracks.count == tracks.count + 2)
        let report = model.error ?? ""
        precondition(report.contains("Damaged.wav: \(model.strings.audioInvalid)") &&
                     report.contains("UnknownCodec.wav: \(model.strings.audioUnsupportedCodec)") &&
                     report.contains("Protected.m4p: \(model.strings.audioProtected)"), report)
        print("PASS: native formats, real codecs, seek/advance, aliases, folder/drop/Finder/playlist import, read-only M4A tags and errors")
    }

    /// Одинаковые правила используются для выдачи, умного списка и очереди при запуске.
    static func checkSearchAndSmartPlaylists(in support: URL, fixtures: URL) throws {
        let manager = FileManager.default
        let root = support.appendingPathComponent("SearchCheck", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("Первый.mp3")
        let secondURL = root.appendingPathComponent("Второй.flac")
        try manager.copyItem(at: fixtures.appendingPathComponent("silence.mp3"), to: firstURL)
        try manager.copyItem(at: fixtures.appendingPathComponent("silence.flac"), to: secondURL)
        var edit = AudioTagEdit()
        edit.fields = [.artist: "Группа Ёлка", .album: "Весна", .genre: "Рок", .year: "2024"]
        _ = try AudioMetadataFile.write(edit, to: firstURL)
        edit.fields = [.artist: "ГРУППА ЁЛКА", .album: "Осень", .genre: "Джаз", .year: "2018"]
        _ = try AudioMetadataFile.write(edit, to: secondURL)
        let first = Track(url: firstURL, duration: 0.26)
        let second = Track(url: secondURL, duration: 0.1)
        let suite = "VibeWave.SearchCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        let firstList = Playlist(name: "Только MP3", tracks: [first])
        let secondList = Playlist(name: "Только FLAC", tracks: [second])
        model.playlists = [firstList, secondList]
        model.selectedID = firstList.id
        model.searchText = "елка"
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [first.id])
        model.searchScope = .library
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [first.id, second.id])
        model.searchOptions.sort = .year
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [second.id, first.id], "Сортировка из настроек")
        model.searchFilter.preservesInputOrder = true
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [first.id, second.id], "Явный ручной порядок")
        model.searchFilter = LibraryQuery()
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [second.id, first.id], "Сброс восстанавливает порядок из настроек")
        model.searchFilter.rules = [QueryRule(.year, .atLeast, "2020"), QueryRule(.format, .equals, "FLAC")]
        waitFor { model.queryReady }
        precondition(model.displayedTracks.isEmpty)
        model.searchFilter.matchAny = true
        model.searchFilter.sort = .year
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [second.id, first.id])

        model.playQuery(second)
        precondition(model.playing && model.current?.id == second.id, model.error ?? "Search playback")
        model.toggle()
        let originalQueue = model.queue
        model.searchText = "не найдено"
        waitFor { model.queryReady }
        precondition(model.displayedTracks.isEmpty && model.queue == originalQueue && model.current?.id == second.id)
        model.stop()
        model.searchText = ""
        model.searchFilter = LibraryQuery()
        model.searchScope = .section
        var list = SmartPlaylist()
        list.name = "Любимые свежие"
        list.query.rules = [QueryRule(.rating, .atLeast, "4"), QueryRule(.added, .withinDays, "30"),
                            QueryRule(.lastPlayed, .missing)]
        list.query.sort = .rating
        list.query.descending = true
        list.query.limit = 1
        model.saveSmartPlaylist(list)
        waitFor { model.queryReady }
        precondition(model.selectedSmart?.id == list.id && model.displayedTracks.isEmpty)
        model.rate(first, stars: 4)
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [first.id])
        model.rate(second, stars: 5)
        waitFor { model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [second.id] && model.smartCounts[list.id] == 1)
        list.name = "Переименованный список"
        model.saveSmartPlaylist(list)
        let restored = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        precondition(restored.smartPlaylists == [list] && restored.playlists == model.playlists)
        restored.deleteSmartPlaylist(list.id)
        let persisted = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        precondition(persisted.smartPlaylists.isEmpty)

        model.selectedID = nil
        model.searchText = "проверка обновления"
        waitFor { model.queryReady }
        precondition(model.displayedTracks.isEmpty)
        var wrote = false
        edit.fields = [.artist: "Проверка обновления"]
        model.writeTags(edit, tracks: [first], job: ImportJob(), progress: { _ in }) { failures, count in
            precondition(failures.isEmpty && count == 1)
            wrote = true
        }
        waitFor { wrote && model.queryReady }
        precondition(model.displayedTracks.map(\.id) == [first.id])
        print("PASS: Unicode search scopes, combined filters and sort, snapshot playback, live smart lists and tag changes")
    }

    /// Реальные MP3 и FLAC редактируются только в тестовой папке.
    static func checkTagsAndListening(in support: URL, fixtures: URL) throws {
        let manager = FileManager.default
        let root = support.appendingPathComponent("TagListeningCheck", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let png = fixtures.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/AppIcon.png")
        let cover = try TrackTagAccess.importArtwork(png)
        var first: Track?
        for ext in ["mp3", "flac"] {
            let file = root.appendingPathComponent("Редактируемый.\(ext)")
            let original = try Data(contentsOf: fixtures.appendingPathComponent("silence.\(ext)"))
            let marker = Data("VibeWave preservation check".utf8)
            let audio: Data
            var tagged: Data
            if ext == "mp3" {
                // Неизвестный кадр ID3v2.4. Его данные и MPEG-поток должны остаться прежними.
                let frameSize = marker.count
                tagged = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, UInt8(frameSize + 10)])
                tagged.append(contentsOf: [0x58, 0x50, 0x52, 0x56, 0, 0, 0, UInt8(frameSize), 0, 0])
                tagged.append(marker)
                audio = original
            } else {
                // FLAC APPLICATION с непрозрачными для редактора данными.
                tagged = Data(original.prefix(42))
                tagged[4] = 0
                tagged.append(contentsOf: [0x82, 0, 0, UInt8(marker.count)])
                tagged.append(marker)
                audio = Data(original.dropFirst(42))
            }
            tagged.append(audio)
            try tagged.write(to: file)
            let before = try AVAudioFile(forReading: file).length
            var edit = AudioTagEdit()
            edit.fields = [.title: "Первая песня", .artist: "Артист", .albumArtist: "Группа",
                           .album: "Альбом", .genre: "Электроника", .year: "2024",
                           .track: "2/10", .disc: "1", .comment: "Комментарий"]
            edit.artwork = .replace(cover)
            let saved = try AudioMetadataFile.write(edit, to: file)
            let metadata = try AudioMetadataFile.read(file)
            precondition(saved.fields == edit.fields && metadata.fields == edit.fields)
            precondition(metadata.artwork?.data == cover.data)
            let revised = try Data(contentsOf: file)
            precondition(revised.suffix(audio.count) == audio && revised.range(of: marker) != nil)
            let after = try AVAudioFile(forReading: file).length
            precondition(before == after)

            var selective = AudioTagEdit()
            selective.fields = [.album: "", .comment: "Новая запись"]
            selective.artwork = .remove
            _ = try AudioMetadataFile.write(selective, to: file)
            let next = try AudioMetadataFile.read(file)
            precondition(next.fields[.album] == nil && next.fields[.comment] == "Новая запись")
            precondition(next.fields[.title] == edit.fields[.title] && next.artwork == nil)
            let beforeRejected = try Data(contentsOf: file)
            selective.fields = [.year: "Ошибка"]
            do {
                _ = try AudioMetadataFile.write(selective, to: file)
                preconditionFailure("Год должен быть проверен до записи")
            } catch AudioMetadataFile.Failure.invalidField(.year) {}
            let afterRejected = try Data(contentsOf: file)
            precondition(beforeRejected == afterRejected)
            if first == nil { first = Track(url: file, duration: 0.26) }
        }

        var session = ListeningSession()
        session.resume(at: 0, time: 100)
        precondition(!session.sample(position: 2, time: 102, duration: 60, threshold: 5))
        session.suspend()
        precondition(!session.sample(position: 45, time: 1_000, duration: 60, threshold: 5))
        session.resume(at: 45, time: 1_000)
        precondition(session.sample(position: 48, time: 1_003, duration: 60, threshold: 5))
        precondition(!session.sample(position: 53, time: 1_008, duration: 60, threshold: 5))

        let suite = "VibeWave.ListeningCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        let track = first!
        let copy = Track(url: track.url, duration: track.duration)
        model.playlists = [Playlist(name: "Первый", tracks: [track]), Playlist(name: "Второй", tracks: [copy])]
        model.rate(track, stars: 4)
        precondition(model.listeningActivity.rating(for: copy.url) == 4)

        var updated = AudioTagEdit()
        updated.fields = [.title: "Название в обеих копиях"]
        var completed = false
        model.writeTags(updated, tracks: [track], job: ImportJob(), progress: { _ in }) { failures, count in
            precondition(failures.isEmpty && count == 1, failures.joined(separator: "\n"))
            completed = true
        }
        waitFor { completed }
        precondition(model.playlists.flatMap(\.tracks).allSatisfy { $0.title == updated.fields[.title] })
        let imported = model.playlists[0].tracks[0]
        model.play(imported, in: [imported], playlistID: model.playlists[0].id)
        waitFor { model.current == nil }
        precondition(model.listeningActivity.events.count == 1 && model.error == nil)
        model.listeningOptions.enabled = false
        model.play(imported, in: [imported], playlistID: model.playlists[0].id)
        waitFor { model.current == nil }
        precondition(model.listeningActivity.events.count == 1)
        let restored = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        precondition(restored.listeningActivity == model.listeningActivity && !restored.listeningOptions.enabled)
        restored.clearListeningHistory()
        precondition(restored.listeningActivity.events.isEmpty && restored.listeningActivity.summaries.isEmpty)
        precondition(restored.listeningActivity.rating(for: track.url) == 4)
        print("PASS: MP3/FLAC tags, artwork, byte-identical audio, unknown metadata, shared ratings and history")
    }

    /// Переносим плейлист вместе с музыкой и проверяем обычный вход drag-and-drop.
    static func checkPlaylistFileExchange(in support: URL, fixtures: URL) throws {
        let manager = FileManager.default
        let original = support.appendingPathComponent("PlaylistOriginal", isDirectory: true)
        let moved = support.appendingPathComponent("PlaylistMoved", isDirectory: true)
        let music = original.appendingPathComponent("Музыка", isDirectory: true)
        try manager.createDirectory(at: music, withIntermediateDirectories: true)
        let one = music.appendingPathComponent("# Первая 100%.mp3")
        let two = original.appendingPathComponent("Вторая.flac")
        try manager.copyItem(at: fixtures.appendingPathComponent("silence.mp3"), to: one)
        try manager.copyItem(at: fixtures.appendingPathComponent("silence.flac"), to: two)
        var track = Track(url: one, duration: 0.26)
        track.title = "Исполнитель, название"
        let tracks = [track, Track(url: two, duration: 0.1)]
        var options = PlaylistFileOptions()
        for format in PlaylistFileFormat.allCases {
            let destination = original.appendingPathComponent("Список.\(format.rawValue)")
            options.exportEncoding = format == .m3u ? .windows1251 : .utf8
            let bytes = try PlaylistFile.encode(tracks, destination: destination, options: options)
            try bytes.write(to: destination)
        }

        options.relativePaths = false
        let absolute = original.appendingPathComponent("Absolute.pls")
        let absoluteData = try PlaylistFile.encode(tracks, destination: absolute, options: options)
        let absoluteEntries = try PlaylistFile.decode(absoluteData, format: .pls, legacyEncoding: .utf8)
        precondition(PlaylistFile.localURL(for: absoluteEntries[0], in: absolute)?.path == one.path)
        let legacy = original.appendingPathComponent("Legacy.m3u")
        options.exportEncoding = .windows1252
        do {
            _ = try PlaylistFile.encode(tracks, destination: legacy, options: options)
            preconditionFailure("Экспорт с потерей символов должен быть отклонён")
        } catch PlaylistFile.Failure.lossyEncoding {}
        do {
            _ = try PlaylistFile.decode(Data([0xFF]), format: .m3u8, legacyEncoding: .windows1251)
            preconditionFailure("M3U8 требует UTF-8")
        } catch PlaylistFile.Failure.invalidEncoding {}
        do {
            _ = try PlaylistFile.decode(Data("#EXTM3U\n#EXT-X-VERSION:6".utf8), format: .m3u8, legacyEncoding: .utf8)
            preconditionFailure("HLS не является списком локальных треков")
        } catch PlaylistFile.Failure.streamingManifest {}

        try manager.moveItem(at: original, to: moved)
        let files = PlaylistFileFormat.allCases.map { moved.appendingPathComponent("Список.\($0.rawValue)") }
        for url in files {
            let entries = try PlaylistFile.read(url, legacyEncoding: .windows1251)
            precondition(entries.first?.title == track.title)
            precondition(entries.map { PlaylistFile.localURL(for: $0, in: url)?.lastPathComponent }
                         == [one.lastPathComponent, two.lastPathComponent])
            precondition(entries.allSatisfy { entry in
                PlaylistFile.localURL(for: entry, in: url).map { manager.fileExists(atPath: $0.path) } == true
            })
        }

        let mixed = moved.appendingPathComponent("Mixed.pls")
        try """
        [Playlist]
        File5=https://example.org/live.mp3
        File3=Вторая.flac
        File4=missing.mp3
        File2=Вторая.flac
        File1=Музыка\\# Первая 100%.mp3
        NumberOfEntries=5
        Version=2
        """.write(to: mixed, atomically: true, encoding: .utf8)
        let suite = "VibeWave.PlaylistCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = support.appendingPathComponent("PlaylistFileCheck")
        let model = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        let providers = (files + [mixed]).compactMap { NSItemProvider(contentsOf: $0) }
        precondition(providers.count == 4 && DropReceiver.receive(providers, model: model, playlistID: nil))
        waitFor { model.playlists.count == 4 || model.error != nil }
        precondition(model.playlists.count == 4 && model.openTracks.isEmpty)
        precondition(model.playlists.allSatisfy { $0.tracks.map(\.url.lastPathComponent) == [one.lastPathComponent, two.lastPathComponent] })
        precondition(model.error?.contains("missing.mp3") == true && model.error?.contains("https://") == true)
        model.error = nil
        model.playlistFileOptions.reportMissingFiles = false
        model.receiveFiles([mixed])
        waitFor { !model.importing }
        precondition(model.playlists.count == 5 && model.error?.contains("https://") == true)
        precondition(model.error?.contains("missing.mp3") == false)
        let saved = moved.appendingPathComponent("Saved.m3u8")
        model.exportPlaylist(model.playlists[0], to: saved, options: model.playlistFileOptions)
        waitFor { manager.fileExists(atPath: saved.path) }
        let exported = try PlaylistFile.read(saved, legacyEncoding: .utf8)
        precondition(exported.map(\.title) == model.playlists[0].tracks.map(\.title))
        let restored = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        precondition(restored.playlists == model.playlists && !restored.playlistFileOptions.reportMissingFiles)
        print("PASS: M3U/M3U8/PLS round-trip, moved paths, legacy encoding, drag import, unsupported entries, export, preferences")
    }

    /// Случайный порядок проверяется по инвариантам, без предположения о конкретной перестановке.
    static func checkShuffleOrder() {
        let first = UUID(), second = UUID(), third = UUID(), added = UUID()
        var order = ShuffleOrder()
        order.reset([], startingAt: first)
        precondition(order.advance(from: first, repeatingQueue: true) == nil)
        order.reset([first], startingAt: first)
        precondition(order.advance(from: first, repeatingQueue: false) == nil)
        precondition(order.advance(from: first, repeatingQueue: true) == first)

        order.reset([first, second, third], startingAt: first)
        let next = order.advance(from: first, repeatingQueue: false)!
        let last = order.next!
        precondition(Set([first, next, last]) == Set([first, second, third]))
        precondition(order.retreat(from: next) == first)
        precondition(order.advance(from: first, repeatingQueue: false) == next)
        order.update([added, next, first], current: next)
        precondition(order.advance(from: next, repeatingQueue: false) == added)
        precondition(order.advance(from: added, repeatingQueue: false) == nil)

        var cycle: [UUID] = []
        var current = added
        for _ in 0..<3 {
            current = order.advance(from: current, repeatingQueue: true)!
            cycle.append(current)
        }
        precondition(cycle.first != added && Set(cycle) == Set([first, next, added]))
        precondition(order.advance(from: current, repeatingQueue: false) == nil)
        print("PASS: shuffle cycles, actual back/forward history, live queue changes")
    }

    /// Публичные команды модели и фактическое завершение аудиофайла используют разные переходы.
    static func checkPlaybackModes(in support: URL, clips: [Track]) {
        let suite = "VibeWave.PlaybackCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = support.appendingPathComponent("PlaybackModeCheck")
        let model = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        precondition(!model.shuffleEnabled && model.repeatMode == .off)
        model.openTracks = clips

        model.repeatMode = .queue
        model.play(clips[1], in: clips)
        waitFor { model.current?.id == clips[0].id || model.error != nil }
        precondition(model.playing && model.error == nil, "Повтор очереди автоматически возвращается к первому треку")

        model.repeatMode = .track
        model.play(clips[0], in: clips)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(model.playing && model.current?.id == clips[0].id && model.error == nil,
                     "Завершившийся трек повторяется")
        model.next()
        precondition(model.current?.id == clips[1].id, "Ручная команда не повторяет трек")
        model.next()
        precondition(model.current == nil, "При повторе одного трека ручной переход не зацикливает очередь")

        model.shuffleEnabled = true
        model.repeatMode = .off
        model.play(clips[1], in: clips)
        precondition(model.nextTrack?.id == clips[0].id)
        model.next()
        precondition(model.current?.id == clips[0].id && model.nextTrack == nil)
        model.previous()
        precondition(model.current?.id == clips[1].id && model.nextTrack?.id == clips[0].id)
        model.removeTrack(clips[0].id, from: nil)
        precondition(model.nextTrack == nil && model.current?.id == clips[1].id)
        model.stop()

        model.repeatMode = .track
        let reopened = PlayerModel(supportDirectory: root, playbackDefaults: defaults)
        precondition(reopened.shuffleEnabled && reopened.repeatMode == .track && !reopened.playing)
        print("PASS: repeat queue and track, manual next, shuffle navigation, settings persistence")
    }

    /// Сквозная проверка автообновления на тестовом приложении: подписанный архив проходит проверки,
    /// подменённый или чужой — нет; установщик ждёт завершения процесса и заменяет приложение на диске.
    static func checkUpdateInstallation(in root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        precondition(Updater.Configuration.fromMainBundle() == nil, "Вне .app автообновление выключено")
        func makeApp(version: String, identifier: String = "local.vibewave.player", in folder: URL) throws -> URL {
            let app = folder.appendingPathComponent("VibeWave.app", isDirectory: true)
            try manager.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try manager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/VibeWave"))
            let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                      "CFBundleExecutable": "VibeWave", "CFBundlePackageType": "APPL"]
            precondition(info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true))
            precondition(shell("/usr/bin/codesign", ["--force", "--sign", "-", app.path]), "Подпись тестового приложения")
            return app
        }
        func makeArchive(_ app: URL, name: String) -> URL {
            let archive = root.appendingPathComponent(name)
            precondition(shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path]))
            return archive
        }
        let keys = UpdateSignature.generateKeyPair()
        func manifest(for archive: URL, version: String, key: String = keys.privateKey) throws -> UpdateManifest {
            let data = try Data(contentsOf: archive)
            return UpdateManifest(version: version, url: archive, sha256: UpdateSignature.sha256Hex(data),
                                  signature: try UpdateSignature.sign(data, privateKey: key))
        }
        let installed = try makeApp(version: "1.0.0", in: root.appendingPathComponent("Applications", isDirectory: true))
        let good = makeArchive(try makeApp(version: "2.0.0", in: root.appendingPathComponent("build", isDirectory: true)), name: "good.zip")
        let goodManifest = try manifest(for: good, version: "2.0.0")
        precondition(goodManifest.isOffered(currentVersion: "1.0.0", systemVersion: ProcessInfo.processInfo.operatingSystemVersion))

        func rejects(_ archive: URL, _ manifest: UpdateManifest, publicKey: String = keys.publicKey) -> Bool {
            let work = root.appendingPathComponent("work-\(UUID().uuidString)")
            return (try? UpdateInstaller.prepare(archive: archive, manifest: manifest, publicKey: publicKey,
                                                 bundleIdentifier: "local.vibewave.player", workDirectory: work)) == nil
        }
        precondition(rejects(good, goodManifest, publicKey: UpdateSignature.generateKeyPair().publicKey), "Чужой ключ отклоняется")
        var tampered = try Data(contentsOf: good)
        tampered[tampered.count / 2] ^= 0xFF
        let tamperedURL = root.appendingPathComponent("tampered.zip")
        try tampered.write(to: tamperedURL)
        precondition(rejects(tamperedURL, goodManifest), "Подменённый архив отклоняется")
        let foreign = makeArchive(try makeApp(version: "2.0.0", identifier: "com.example.other",
                                              in: root.appendingPathComponent("foreign", isDirectory: true)), name: "foreign.zip")
        let foreignManifest = try manifest(for: foreign, version: "2.0.0")
        precondition(rejects(foreign, foreignManifest), "Чужое приложение отклоняется")
        let wrongVersion = try manifest(for: good, version: "3.0.0")
        precondition(rejects(good, wrongVersion), "Версия внутри должна совпадать с обещанной")

        let work = root.appendingPathComponent("work", isDirectory: true)
        let prepared = try UpdateInstaller.prepare(archive: good, manifest: goodManifest, publicKey: keys.publicKey,
                                                   bundleIdentifier: "local.vibewave.player", workDirectory: work)
        // Установщик ждёт завершения «приложения» (здесь — короткого процесса) и только потом меняет файлы.
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["0.5"]
        try running.run()
        let installer = try UpdateInstaller.launchInstaller(newApp: prepared, target: installed, waitingFor: running.processIdentifier,
                                                            relaunch: false, workDirectory: work)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        precondition(installer.isRunning, "Установщик ждёт выхода приложения")
        precondition(NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String == "1.0.0")
        running.waitUntilExit()
        waitFor { !installer.isRunning }
        precondition(installer.terminationStatus == 0, "Установщик завершился без ошибок")
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        precondition(info?["CFBundleShortVersionString"] as? String == "2.0.0", "Приложение заменено новой версией")
        precondition(shell("/usr/bin/codesign", ["--verify", "--strict", installed.path]), "Подпись нового приложения цела")
        precondition(!manager.fileExists(atPath: installed.path + ".vibewave-previous"), "Прежняя версия убрана")
        print("PASS: auto-update signature checks (foreign key, tampering, other app, version) and background install after exit")
    }

    @discardableResult
    static func shell(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func findCaption(in view: NSView) -> RetroCaptionView? {
        if let caption = view as? RetroCaptionView { return caption }
        for child in view.subviews {
            if let found = findCaption(in: child) { return found }
        }
        return nil
    }
    static func checkPlaybackSession(in support: URL, fixtures: URL) throws {
        let directory = support.appendingPathComponent("PlaybackSessionCheck")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "org.vibewave.session-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = fixtures.appendingPathComponent("silence.flac")
        let urls = (1...3).map { directory.appendingPathComponent("file-\($0).flac") }
        for url in urls { try FileManager.default.copyItem(at: fixture, to: url) }
        let tracks = urls.map { Track(url: $0, duration: 1) }

        let model = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        precondition(!model.restorePlaybackOnLaunch)
        model.restorePlaybackOnLaunch = true
        model.openTracks = tracks
        model.shuffleEnabled = true
        model.play(tracks[0], in: tracks)
        precondition(model.playing, model.error ?? "playback did not start")
        model.next()
        precondition(model.playing)
        let current = model.current!
        let next = model.nextTrack!
        model.toggle()
        model.seek(model.duration / 2)
        let position = model.engine.currentTime
        precondition(position > 0)
        model.savePlaybackSession()
        model.stop(preservingSession: true)

        let restored = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        precondition(restored.restorePlaybackOnLaunch)
        restored.restorePlaybackSession()
        precondition(!restored.playing && !restored.engine.isPlaying && restored.timer == nil)
        precondition(restored.current?.id == current.id && restored.queue == tracks && restored.openTracks == tracks)
        precondition(restored.nextTrack == next && abs(restored.position - position) < 0.02)
        restored.toggle()
        precondition(restored.playing)
        restored.toggle()
        restored.seek(0)
        restored.previous()
        precondition(restored.current == tracks[0] && restored.playing)
        restored.stop(preservingSession: true)

        try FileManager.default.removeItem(at: current.url)
        let missing = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        missing.restorePlaybackSession()
        precondition(missing.current != nil && missing.current?.id != current.id)
        precondition(!missing.playing && !missing.engine.isPlaying && missing.position == 0)
        missing.stop()
        let cleared = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        cleared.restorePlaybackSession()
        precondition(cleared.current == nil && cleared.queue.isEmpty)

        missing.play(tracks[0], in: [tracks[0]])
        precondition(missing.playing)
        missing.savePlaybackSession()
        missing.restorePlaybackOnLaunch = false
        precondition(missing.playing)
        let disabled = PlayerModel(supportDirectory: directory, playbackDefaults: defaults)
        let deleted = try disabled.playbackSessionStore.load()
        precondition(deleted == nil && !disabled.restorePlaybackOnLaunch)
        missing.stop()

        let corrupted = Data("corrupted".utf8)
        try corrupted.write(to: disabled.playbackSessionStore.url, options: .atomic)
        disabled.restorePlaybackOnLaunch = true
        disabled.restorePlaybackSession()
        disabled.savePlaybackSession()
        let unchanged = try Data(contentsOf: disabled.playbackSessionStore.url)
        precondition(disabled.current == nil && unchanged == corrupted)
        print("PASS: paused restoration, exact queue and seek, shuffle history, missing file fallback, stop, disable, corrupt snapshot")
    }

    static func checkApplicationSettings(in support: URL) {
        let suite = "VibeWave.SettingsChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SettingsPreferences(defaults: defaults)
        precondition(!preferences.quitOnClose && preferences.showArtwork && !preferences.confirmTagEdits)
        precondition(preferences.automaticUpdates && preferences.mediaKeys)
        preferences.quitOnClose = true
        preferences.showArtwork = false
        preferences.confirmTagEdits = true
        preferences.mediaKeys = false
        preferences.automaticUpdates = false
        let restored = SettingsPreferences(defaults: defaults)
        precondition(restored.quitOnClose && !restored.showArtwork && restored.confirmTagEdits)
        precondition(!restored.mediaKeys && !restored.automaticUpdates)

        let model = PlayerModel(supportDirectory: support.appendingPathComponent("AppSettings"), playbackDefaults: defaults)
        model.adjustVolume(by: 10)
        precondition(model.volume == 1 && model.engine.volume == 1)
        model.muted = true
        model.adjustVolume(by: -0.5)
        precondition(model.volume == 0.5 && model.engine.volume == 0)
        model.muted = false
        precondition(model.engine.volume == 0.5)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [UpdateCheckStub.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://vibewave-test.invalid/update.json")!
        let configuration = Updater.Configuration(feedURL: url, publicKey: "test", bundleURL: support,
                                                  bundleIdentifier: "local.vibewave.test", currentVersion: "2.0.0")
        let updater = Updater(model: model, configuration: configuration, session: session)
        updater.checkOnLaunch { restored.automaticUpdates }
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        precondition(updater.status == .idle, "Отключённая автоматическая проверка")
        updater.checkNow()
        waitFor { updater.status == .noCompatibleUpdate || updater.status == .failed }
        precondition(updater.status == .noCompatibleUpdate, "Ручная проверка при отключённой автоматической")
        var failedConfiguration = configuration
        failedConfiguration.feedURL = url.appendingPathComponent("error")
        let failed = Updater(model: model, configuration: failedConfiguration, session: session)
        failed.checkNow()
        waitFor { failed.status == .failed }
        print("PASS: application preferences, mute and volume, update check settings and error status")
    }

    static func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(condition(), "Async drop handler timed out")
    }
}


/// Отдаёт тестовый манифест без запроса к GitHub.
private final class UpdateCheckStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vibewave-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path == "/update.json" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let manifest = UpdateManifest(version: "2.0.0", url: url.appendingPathComponent("release.zip"),
                                      sha256: "", signature: "")
        do {
            let data = try JSONEncoder().encode(manifest)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
