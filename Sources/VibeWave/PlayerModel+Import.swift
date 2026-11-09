import AppKit
import Foundation
import UniformTypeIdentifiers
import VibeWaveCore

/// Добавление файлов и папок. Чтение идёт в фоне (MediaScanner), назначение
/// фиксируется до начала работы, результат применяется на главном потоке.
/// Одновременно выполняется одна задача; её можно отменить — тогда библиотека не меняется.
extension PlayerModel {
    /// Кнопка добавляет в выбранный пользователем раздел: очередь или плейлист.
    func importFiles() {
        guard !importing else { return }
        let targetID = isPlaylist(selectedID) ? selectedID : nil
        let panel = NSOpenPanel()
        panel.title = targetID == nil ? strings.panelAddOutside : strings.panelAddToPlaylist
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mp3"), UTType(filenameExtension: "flac")].compactMap { $0 }
            + PlaylistFileFormat.allCases.map(\.contentType)
        guard panel.runModal() == .OK else { return }
        receiveFiles(panel.urls, into: targetID)
    }

    /// Открытие через Finder или Dock всегда относится к очереди вне плейлистов,
    /// даже если перед этим пользователь просматривал сохранённый плейлист.
    func openFiles(_ urls: [URL]) {
        guard !importing else { error = strings.errorImportBusy; return }
        selectedID = nil
        receiveFiles(urls, autoplay: true)
    }

    /// nil — очередь. Отсутствующий или удалённый плейлист не создаётся заново.
    /// Папки из Finder добавляются как папки библиотеки; файлы в папку не перетаскиваются.
    func receiveFiles(_ urls: [URL], into playlistID: UUID? = nil, before destination: UUID? = nil,
                      autoplay: Bool = false) {
        guard !importing else { error = strings.errorImportBusy; return }
        let directories = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !directories.contains($0) }
        let playlists = files.filter { PlaylistFileFormat(url: $0) != nil }
        let targetID = isFolder(playlistID) ? nil : playlistID
        if !playlists.isEmpty {
            let audio = files.filter { PlaylistFileFormat(url: $0) == nil }
            importPlaylistFiles(playlists, audio: audio, folders: directories, into: targetID,
                                before: destination, autoplay: autoplay)
        } else if !directories.isEmpty {
            addFolders(directories)
        } else {
            importURLs(urls, into: targetID, before: destination, autoplay: autoplay)
        }
    }

    func chooseFolder() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = strings.addMusicFolder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    /// Прерывает текущую задачу. Интерфейс разблокируется сразу; фоновые потоки
    /// останавливаются на ближайшем файле, а их результат отбрасывается.
    func cancelImport() {
        guard let job = importJob else { return }
        job.cancel()
        endJob()
    }

    // MARK: Задачи

    func addFolders(_ urls: [URL]) {
        guard !importing else { error = strings.errorImportBusy; return }
        let fresh = urls.filter { url in !folders.contains { $0.url.standardizedFileURL == url.standardizedFileURL } }
        guard !fresh.isEmpty else { error = strings.errorFolderAlreadyAdded; return }
        let job = beginJob(fresh.count == 1 ? .folder(fresh[0].lastPathComponent) : .folders(fresh.count))
        let unavailable = strings.errorFolderUnavailableShort
        let progress = progressHandler(for: job)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = try? fresh.map { url -> (MusicFolder?, [String]) in
                let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                guard let scan = try MediaScanner.scanFolder(url, bookmark: nil, job: job, progress: progress) else {
                    return (nil, [unavailable(url.lastPathComponent)])
                }
                return (MusicFolder(url: url, bookmark: bookmark, tracks: scan.added.tracks), scan.added.failures)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.finishJob(job), let scanned = scanned else { return }
                let added = scanned.compactMap(\.0)
                self.folders += added
                if let first = added.first { self.selectedID = first.id }
                self.save()
                self.report(failures: scanned.flatMap(\.1))
            }
        }
    }

    /// Уже известные файлы не открываются повторно: читаются только новые.
    func rescanFolder(_ id: UUID) {
        guard !importing, let folder = folders.first(where: { $0.id == id }) else { return }
        let known = Set(folder.tracks.map { $0.url.standardizedFileURL })
        let job = beginJob(.folder(folder.name))
        let progress = progressHandler(for: job)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scan = try? MediaScanner.scanFolder(folder.url, bookmark: folder.bookmark, known: known, job: job, progress: progress)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.finishJob(job) else { return }
                // Недоступная папка не очищается: список треков и их порядок сохраняются.
                guard let scan = scan else {
                    self.error = self.strings.errorFolderUnavailable(folder.name)
                    return
                }
                guard let index = self.folders.firstIndex(where: { $0.id == id }) else { return }
                self.folders[index].merge(files: scan.files, added: scan.added.tracks)
                self.invalidateQueryTags(for: scan.files)
                self.refreshPlaybackQueue()
                self.save()
                self.report(failures: scan.added.failures)
            }
        }
    }

    /// Общий путь импорта файлов в очередь или плейлист.
    func importURLs(_ urls: [URL], into targetID: UUID?, before destination: UUID? = nil, autoplay: Bool = false) {
        guard !importing else { return }
        guard tracks(in: targetID) != nil else { error = strings.errorPlaylistGone; return }
        let supported = urls.filter { Track.accepts($0) && MusicFiles.isRegularFile($0) }
        guard !supported.isEmpty else { error = strings.errorNoSupportedFiles; return }
        let job = beginJob(.files)
        let progress = progressHandler(for: job)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let batch = try? MediaScanner.readTracks(supported, job: job, progress: progress)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.finishJob(job), let batch = batch else { return }
                self.apply(batch, into: targetID, before: destination, autoplay: autoplay)
            }
        }
    }

    /// Тот же вход используется для меню, Finder и перетаскивания. Аудиофайлы
    /// смешанного выбора идут в обычное назначение, а списки сохраняются отдельно.
    private func importPlaylistFiles(_ urls: [URL], audio: [URL], folders: [URL], into targetID: UUID?,
                                     before destination: UUID?, autoplay: Bool) {
        let job = beginJob(.files)
        let progress = progressHandler(for: job)
        let options = playlistFileOptions
        let strings = strings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = PlaylistImportResult()
            var audioBatch = MediaScanner.Batch()
            do {
                for url in urls {
                    if job.isCancelled { throw CancellationError() }
                    try result.read(url, options: options, strings: strings, job: job, progress: progress)
                }
                let supportedAudio = audio.filter { Track.accepts($0) && MusicFiles.isRegularFile($0) }
                audioBatch = try MediaScanner.readTracks(supportedAudio, job: job, progress: progress)
                if !audio.isEmpty && supportedAudio.isEmpty { result.failures.append(strings.errorNoSupportedFiles) }
            } catch {
                // Отменённая задача уже разблокировала интерфейс. Старый результат отбрасывается.
                DispatchQueue.main.async { [weak self] in _ = self?.finishJob(job) }
                return
            }
            let imported = result
            let batch = audioBatch
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.finishJob(job) else { return }
                if !batch.tracks.isEmpty || !batch.failures.isEmpty {
                    self.apply(batch, into: targetID, before: destination, autoplay: autoplay)
                }
                if let last = imported.playlists.last {
                    self.playlists += imported.playlists
                    self.selectedID = last.id
                    self.save()
                }
                self.report(failures: imported.failures + batch.failures)
                if !folders.isEmpty { self.addFolders(folders) }
            }
        }
    }

    private func apply(_ batch: MediaScanner.Batch, into targetID: UUID?, before destination: UUID?, autoplay: Bool) {
        guard var tracks = tracks(in: targetID) else {
            error = strings.errorPlaylistDeletedDuringImport
            return
        }
        for track in batch.tracks {
            guard !tracks.contains(where: { $0.url.standardizedFileURL == track.url.standardizedFileURL }) else { continue }
            let insertion = destination.flatMap { id in tracks.firstIndex { $0.id == id } } ?? tracks.endIndex
            tracks.insert(track, at: insertion)
        }
        replaceTracks(tracks, in: targetID)
        refreshPlaybackQueue()
        if targetID != nil { save() }
        if autoplay, let firstURL = batch.tracks.first?.url,
           let first = tracks.first(where: { $0.url.standardizedFileURL == firstURL.standardizedFileURL }) {
            play(first, in: tracks, playlistID: targetID)
        }
        report(failures: batch.failures)
    }

    private func report(failures: [String]) {
        guard !failures.isEmpty else { return }
        // Длинный список имён не помещается в окно сообщения.
        error = strings.errorCouldNotOpen(Array(failures.prefix(10)), max(0, failures.count - 10))
    }

    private func beginJob(_ kind: ImportProgress.Kind) -> ImportJob {
        let job = ImportJob()
        importJob = job
        importing = true
        importProgress = ImportProgress(kind: kind)
        return job
    }

    private func endJob() {
        importJob = nil
        importing = false
        importProgress = nil
    }

    /// true — результат ещё актуален: задача не отменена и не заменена другой.
    private func finishJob(_ job: ImportJob) -> Bool {
        guard importJob === job else { return false }
        endJob()
        return !job.isCancelled
    }

    /// Обработчик прогресса для фоновых потоков: прореживает отчёты и передаёт их на главный поток.
    private func progressHandler(for job: ImportJob) -> MediaScanner.Progress {
        { [weak self] done, total in
            guard job.shouldReport(final: total.map { done >= $0 } ?? false) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.importJob === job else { return }
                self.importProgress?.done = done
                self.importProgress?.total = total
            }
        }
    }
}
