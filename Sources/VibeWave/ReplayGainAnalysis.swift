import Foundation
import VibeWaveCore

@MainActor
final class ReplayGainStore {
    struct Stamp: Codable, Equatable, Sendable {
        let modified: Date
        let size: Int

        init(_ url: URL) throws {
            let info = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modified = info.contentModificationDate, let size = info.fileSize else {
                throw CocoaError(.fileReadUnknown)
            }
            self.modified = modified
            self.size = size
        }
    }

    struct Entry: Codable, Sendable {
        let stamp: Stamp
        let values: ReplayGainValues
    }

    private let url: URL
    private var entries: [String: Entry] = [:]
    private let loadError: Error?

    init(url: URL) {
        self.url = url
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loadError = nil
        } catch {
            loadError = error
        }
    }

    func values(for track: Track) -> ReplayGainValues? {
        entry(for: track)?.values
    }

    func entry(for track: Track) -> Entry? {
        guard let entry = entries[track.url.standardizedFileURL.path], entry.values.isValid else { return nil }
        return try? TrackTagAccess.withURL(track) { url in
            try Stamp(url) == entry.stamp ? entry : nil
        }
    }

    /// Сначала атомарно обновляем файл. До успешной записи рабочий кэш не меняется.
    func merge(_ updates: [String: Entry]) throws {
        if let loadError = loadError { throw loadError }
        let merged = entries.merging(updates) { _, new in new }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(merged).write(to: url, options: .atomic)
        entries = merged
    }
}

private struct GainAnalysisFile: Sendable {
    struct Album: Hashable, Sendable {
        let title: String
        let artist: String
    }

    let path: String
    let stamp: ReplayGainStore.Stamp
    let measurement: LoudnessMeasurement
    let album: Album?

    init(_ track: Track, job: ImportJob) throws {
        (path, stamp, measurement, album) = try TrackTagAccess.withURL(track) { url in
            let before = try ReplayGainStore.Stamp(url)
            let tags = try? AudioMetadataFile.read(url, includeArtwork: false).fields
            let result = try LoudnessAnalyzer.analyze(url, isCancelled: { job.isCancelled })
            guard try ReplayGainStore.Stamp(url) == before else { throw AudioMetadataFile.Failure.changedDuringWrite }
            let title = tags?[.album]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let artist = (tags?[.albumArtist] ?? tags?[.artist] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (track.url.standardizedFileURL.path, before, result, title.isEmpty ? nil : Album(title: title, artist: artist))
        }
    }
}

extension PlayerModel {
    var gainTracks: [Track] {
        var seen = Set<URL>()
        return displayedTracks.filter { seen.insert($0.url.standardizedFileURL).inserted }
    }

    func analyzeGain(_ tracks: [Track]) {
        guard gainJob == nil, !writingTags, !tracks.isEmpty else { return }
        let job = ImportJob()
        gainJob = job
        gainReport = nil
        gainProgress = (0, tracks.count)
        let russian = LanguageSettings.shared.language == .ru
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var files: [GainAnalysisFile] = []
            var failures: [String] = []
            var updates: [String: ReplayGainStore.Entry] = [:]
            for (index, track) in tracks.enumerated() {
                guard !job.isCancelled else { break }
                do { files.append(try GainAnalysisFile(track, job: job)) }
                catch where job.isCancelled { break }
                catch { failures.append("\(track.title) — \(error.localizedDescription)") }
                if job.shouldReport(final: index + 1 == tracks.count) {
                    DispatchQueue.main.async { [weak self] in self?.gainProgress = (index + 1, tracks.count) }
                }
            }
            do {
                // Если часть файлов пропущена, оставляем только трековые результаты.
                // Так неполный альбом не получит общее усиление по ошибке.
                let groups = Dictionary(grouping: files) { failures.isEmpty ? $0.album : nil }
                for (album, group) in groups {
                    let results = try album.map { _ in
                        try LoudnessAnalyzer.replayGain(for: group.map(\.measurement), isCancelled: { job.isCancelled })
                    } ?? group.map { ReplayGainValues(trackGain: $0.measurement.gain, trackPeak: $0.measurement.peak) }
                    for (file, values) in zip(group, results) {
                        updates[file.path] = ReplayGainStore.Entry(stamp: file.stamp, values: values)
                    }
                }
            } catch where job.isCancelled {
                // Отменённый запуск оставляет предыдущий кэш целиком.
            } catch {
                failures.append(error.localizedDescription)
            }
            let results = updates
            let issues = failures
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                defer {
                    self.gainJob = nil
                    self.gainProgress = nil
                }
                guard !job.isCancelled else {
                    self.gainReport = russian ? "Анализ отменён." : "Analysis cancelled."
                    return
                }
                do {
                    if !results.isEmpty { try self.gainStore.merge(results) }
                    self.configureAudio()
                    let count = russian ? "Проанализировано: \(results.count) из \(tracks.count)." :
                        "Analyzed \(results.count) of \(tracks.count)."
                    self.gainReport = ([count] + issues.prefix(5)).joined(separator: "\n")
                } catch {
                    self.gainReport = error.localizedDescription
                }
            }
        }
    }

    func writeAnalyzedGain(_ tracks: [Track]) {
        guard gainJob == nil, !writingTags else { return }
        var edits: [(Track, AudioTagEdit)] = []
        var stamps: [UUID: ReplayGainStore.Stamp] = [:]
        for track in tracks {
            guard AudioFormat(url: track.url)?.writesTags == true,
                  let entry = gainStore.entry(for: track), !entry.values.isEmpty else { continue }
            var edit = AudioTagEdit()
            edit.replayGain = entry.values
            edits.append((track, edit))
            stamps[track.id] = entry.stamp
        }
        let russian = LanguageSettings.shared.language == .ru
        guard !edits.isEmpty else {
            gainReport = russian ? "В разделе нет актуальных результатов для MP3 или FLAC." :
                "There are no current MP3 or FLAC results in this view."
            return
        }
        let job = ImportJob()
        gainJob = job
        gainReport = nil
        gainProgress = (0, edits.count)
        writeTagEdits(edits, job: job, validate: { [stamps] track, url in
            guard try ReplayGainStore.Stamp(url) == stamps[track.id] else {
                throw AudioMetadataFile.Failure.changedDuringWrite
            }
        }, progress: { [weak self] count in
            self?.gainProgress = (count, edits.count)
        }, completion: { [weak self] issues, count in
            let summary = russian ? "Записано в файлы: \(count) из \(edits.count)." :
                "Updated \(count) of \(edits.count) files."
            self?.gainReport = ([summary] + issues.prefix(5)).joined(separator: "\n")
            self?.gainProgress = nil
            self?.gainJob = nil
        })
    }
}
