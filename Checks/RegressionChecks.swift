import Foundation
import AVFoundation
import AppKit
import VibeWaveCore

/// Запускается без XCTest и проверяет реальную модель на временной библиотеке.
@main
@MainActor
struct RegressionChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
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
        print("PASS: real MP3/FLAC import and valid app icon")
        print("PASS: migration, reorder up/down/end, cross-playlist move, duplicates, persistence, payload, formats")
    }
    static func findCaption(in view: NSView) -> RetroCaptionView? {
        if let caption = view as? RetroCaptionView { return caption }
        for child in view.subviews {
            if let found = findCaption(in: child) { return found }
        }
        return nil
    }
    static func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(condition(), "Async drop handler timed out")
    }
}
