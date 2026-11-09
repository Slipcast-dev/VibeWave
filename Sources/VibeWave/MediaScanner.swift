import AVFoundation
import Foundation
import VibeWaveCore

/// Состояние фоновой задачи импорта для интерфейса.
struct ImportProgress: Equatable {
    var title: String
    var done = 0
    /// nil — число файлов ещё неизвестно (идёт поиск в папке).
    var total: Int?

    var label: String {
        guard let total = total else { return "\(title): поиск…" }
        return "\(title): \(done) из \(total)"
    }
}

/// Фоновая задача импорта или сканирования. Отмена и частота отчётов
/// защищены блокировкой: к задаче обращаются потоки сканирования и главный поток.
final class ImportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = Date.distantPast

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Не чаще 10 раз в секунду, чтобы не перегружать SwiftUI; последний отчёт проходит всегда.
    func shouldReport(final: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard final || now.timeIntervalSince(lastReport) >= 0.1 else { return false }
        lastReport = now
        return true
    }
}

/// Чтение аудиофайлов вне главного потока. Ничего не знает о модели и интерфейсе.
enum MediaScanner {
    /// (готово, всего); всего == nil, пока список файлов не известен.
    typealias Progress = @Sendable (Int, Int?) -> Void

    struct Batch: Sendable {
        var tracks: [Track] = []
        var failures: [String] = []
    }

    struct FolderScan: Sendable {
        /// Все подходящие файлы папки, включая уже известные.
        var files: [URL]
        /// Треки только для новых файлов.
        var added: Batch
    }

    /// Открывает файлы параллельно; порядок результата совпадает с порядком urls.
    static func readTracks(_ urls: [URL], job: ImportJob, progress: Progress) throws -> Batch {
        guard !urls.isEmpty else { return Batch() }
        var results = [Result<Track, Error>?](repeating: nil, count: urls.count)
        let counter = Counter()
        progress(0, urls.count)
        results.withUnsafeMutableBufferPointer { buffer in
            // Каждый поток пишет только в свою ячейку буфера.
            let slots = buffer
            DispatchQueue.concurrentPerform(iterations: urls.count) { index in
                guard !job.isCancelled else { return }
                slots[index] = probe(urls[index])
                progress(counter.increment(), urls.count)
            }
        }
        if job.isCancelled { throw CancellationError() }
        var batch = Batch()
        for (url, result) in zip(urls, results) {
            switch result {
            case .success(let track)?: batch.tracks.append(track)
            case .failure(let error)?: batch.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            case nil: break
            }
        }
        return batch
    }

    /// nil — папка недоступна. known — стандартизованные URL уже известных треков:
    /// их не открываем повторно, поэтому обновление большой папки почти мгновенно.
    static func scanFolder(_ folder: URL, bookmark: Data?, known: Set<URL> = [], job: ImportJob,
                           progress: Progress) throws -> FolderScan? {
        var root = folder
        if let data = bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                       bookmarkDataIsStale: &stale) { root = resolved }
        }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        progress(0, nil)
        guard let files = try MusicFiles.collect(in: root, isCancelled: { job.isCancelled }) else { return nil }
        let fresh = files.filter { !known.contains($0.standardizedFileURL) }
        return FolderScan(files: files, added: try readTracks(fresh, job: job, progress: progress))
    }

    /// Проверка файла тем же декодером, что и при воспроизведении.
    private static func probe(_ url: URL) -> Result<Track, Error> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            // В локальной сборке без App Sandbox app-scope key может отсутствовать:
            // необязательная закладка не должна отклонять исправную музыку.
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            return .success(Track(url: url, duration: audio.duration, bookmark: bookmark))
        } catch { return .failure(error) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
